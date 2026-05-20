import torch
import numpy as np
import argparse
import time
import os
from pathlib import Path
from torch.utils.data import DataLoader
from torchvision import transforms
from torchvision.transforms.functional import InterpolationMode
from tqdm import tqdm
from sklearn.metrics import f1_score, precision_score, recall_score, confusion_matrix, classification_report
import cv2

# TensorRT 相关库
import tensorrt as trt
import pycuda.driver as cuda
import pycuda.autoinit

# 尝试导入 jtop 库用于获取 Jetson 硬件状态
try:
    from jtop import jtop
    HAS_JTOP = True
except ImportError:
    HAS_JTOP = False
    print("未安装 jetson-stats (jtop)，无法获取功耗信息")

class Config:
    BASE_DIR        = Path(__file__).resolve().parent
    DATA_ROOT       = BASE_DIR / 'MF_Datasets' 
    HYPERPARAMS = {
        'num_frames':       8,
        'batch_size':       1,
        'num_workers':      0,
    }

class HardwareMonitor:
    """基于 jtop 的硬件状态监控类"""
    def __init__(self):
        self.enabled = False
        self.jetson = None
        
        if HAS_JTOP:
            try:
                self.jetson = jtop()
                self.jetson.start()
                if self.jetson.ok():
                    self.enabled = True
                    print("JTOP 监控服务已启动")
                else:
                    print("JTOP 服务启动失败")
            except Exception as e:
                print(f"JTOP 初始化异常: {e}")

    def get_metrics(self):
        """读取当前的显存占用(MB)和总功耗(W)"""
        if not self.enabled or not self.jetson.ok():
            return 0, 0
        try:
            # 获取内存使用情况
            mem_dict = self.jetson.memory.get('RAM', {})
            mem_used_kb = mem_dict.get('used', 0)
            mem_used_mb = mem_used_kb / 1024.0
            
            # 获取总功耗
            power_dict = self.jetson.power.get('tot', {})
            power_mw = power_dict.get('power', power_dict.get('cur', power_dict.get('avg', 0)))
            power_w = power_mw / 1000.0
            
            return mem_used_mb, power_w
        except Exception:
            return 0, 0

    def close(self):
        if self.jetson:
            self.jetson.close()

    def __del__(self):
        self.close()

class TRTWrapper:
    """TensorRT 推理封装类 (适配 TensorRT 10.x+)"""
    def __init__(self, engine_path):
        self.logger = trt.Logger(trt.Logger.WARNING)
        self.runtime = trt.Runtime(self.logger)
        
        print(f"正在加载 TensorRT 引擎: {engine_path}")
        with open(engine_path, "rb") as f:
            self.engine = self.runtime.deserialize_cuda_engine(f.read())
        
        self.context = self.engine.create_execution_context()
        
        self.inputs = []
        self.outputs = []
        self.stream = cuda.Stream()
        
        num_io = self.engine.num_io_tensors
        for i in range(num_io):
            name = self.engine.get_tensor_name(i)
            
            # 获取张量形状和数据类型
            shape = self.engine.get_tensor_shape(name)
            dtype = trt.nptype(self.engine.get_tensor_dtype(name))
            
            # 计算显存大小 (处理动态形状为固定最大值)
            vol = trt.volume(shape)
            if vol < 0: 
                vol = 1 * 8 * 3 * 240 * 240 
            
            size = vol * np.dtype(dtype).itemsize
            device_mem = cuda.mem_alloc(size)
            
            # 区分输入与输出绑定
            if self.engine.get_tensor_mode(name) == trt.TensorIOMode.INPUT:
                self.inputs.append({
                    'name': name,
                    'host': cuda.pagelocked_empty(vol, dtype),
                    'device': device_mem,
                    'shape': shape
                })
            else:
                self.outputs.append({
                    'name': name,
                    'host': cuda.pagelocked_empty(vol, dtype),
                    'device': device_mem,
                    'shape': shape
                })

    def infer(self, input_data):
        """执行推理过程"""
        # 拷贝数据 Host -> PageLocked Memory
        np.copyto(self.inputs[0]['host'], input_data.ravel())
        
        # 绑定地址并设置输入形状
        for inp in self.inputs:
            cuda.memcpy_htod_async(inp['device'], inp['host'], self.stream)
            self.context.set_tensor_address(inp['name'], int(inp['device']))
            self.context.set_input_shape(inp['name'], inp['shape'])

        for out in self.outputs:
            self.context.set_tensor_address(out['name'], int(out['device']))

        # 执行异步推理
        self.context.execute_async_v3(stream_handle=self.stream.handle)
        
        # 拷贝结果 Device -> Host
        for out in self.outputs:
            cuda.memcpy_dtoh_async(out['host'], out['device'], self.stream)
            
        self.stream.synchronize()
        return self.outputs[0]['host']

class VideoDataset(torch.utils.data.Dataset):
    """视频数据集加载类"""
    def __init__(self, root, transform=None, num_frames=8):
        self.root = Path(root)
        self.transform = transform
        self.num_frames = num_frames
        self.samples = self._make_dataset(self.root)
        if len(self.samples) == 0:
            raise RuntimeError(f"在 {self.root} 中未发现视频文件")

    def _make_dataset(self, directory):
        instances = []
        directory = Path(directory)
        
        if not directory.exists():
            raise FileNotFoundError(f"目录不存在: {directory}")

        classes = sorted([d.name for d in directory.iterdir() if d.is_dir()])
        class_to_idx = {cls_name: i for i, cls_name in enumerate(classes)}
        
        for target_class in classes:
            class_dir = directory / target_class
            target_idx = class_to_idx[target_class]
            for path in sorted(class_dir.glob('*.avi')):
                instances.append((path, target_idx))
        return instances

    def video_loader(self, path):
        cap = cv2.VideoCapture(str(path))
        frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        if frame_count <= 0:
            cap.release()
            raise ValueError(f"无法读取视频: {path}")
        indices = np.linspace(0, frame_count - 1, self.num_frames, dtype=int)
        frames = []
        for idx in indices:
            cap.set(cv2.CAP_PROP_POS_FRAMES, idx)
            ret, frame = cap.read()
            if ret:
                frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                frame = torch.from_numpy(frame).permute(2, 0, 1).float() / 255.0
                frames.append(frame)
            else:
                if frames: frames.append(frames[-1])
        cap.release()
        if len(frames) == 0: raise ValueError(f"视频为空: {path}")
        while len(frames) < self.num_frames:
            frames.append(frames[-1])
        return torch.stack(frames)

    def __getitem__(self, index):
        path, target = self.samples[index]
        video = self.video_loader(path)
        if self.transform is not None:
            video = torch.stack([self.transform(frame) for frame in video])
        return video, target, str(path)

    def __len__(self):
        return len(self.samples)

def validate_trt(trt_model, loader, classes):
    all_preds = []
    all_targets = []
    latencies = []
    gpu_powers = []
    gpu_mems = []
    
    # === 新增：用于存储误判样本的列表 ===
    misclassified_samples = [] 
    
    monitor = HardwareMonitor()

    print("开始 TensorRT 推理...")
    
    # GPU 预热
    dummy_input = np.random.randn(1, 8, 3, 240, 240).astype(np.float32)
    print("正在预热 GPU...")
    for _ in range(20):
        _ = trt_model.infer(dummy_input)
    
    # 循环推理
    for i, (data, target, paths) in enumerate(tqdm(loader)):
        input_numpy = data.numpy().astype(np.float32)
        
        start_time = time.time()
        output_flat = trt_model.infer(input_numpy)
        end_time = time.time()
        latencies.append((end_time - start_time) * 1000)
        
        # 采样硬件数据 (每20次迭代采样一次)
        if monitor.enabled and (i % 20 == 0):
            mem, power = monitor.get_metrics()
            if mem > 0: gpu_mems.append(mem)
            if power > 0: gpu_powers.append(power)

        preds = np.argmax(output_flat)
        
        # === 新增：误判检测逻辑 ===
        # 注意：这里假设 batch_size=1
        true_label_idx = target.numpy()[0]
        if preds != true_label_idx:
            video_name = Path(paths[0]).name # 获取文件名
            true_class_name = classes[true_label_idx]
            pred_class_name = classes[preds]
            
            # 记录误判信息
            error_info = f"视频ID: {video_name:<30} | 真实类别: {true_class_name} -> 预测类别: {pred_class_name}"
            misclassified_samples.append(error_info)
        # ==========================

        all_preds.append(preds)
        all_targets.extend(target.numpy())
    
    monitor.close()

    all_preds = np.array(all_preds)
    all_targets = np.array(all_targets)
    
    # 计算分类指标
    acc = (all_preds == all_targets).mean() * 100
    f1 = f1_score(all_targets, all_preds, average='weighted')
    precision = precision_score(all_targets, all_preds, average='weighted', zero_division=0)
    recall = recall_score(all_targets, all_preds, average='weighted', zero_division=0)
    
    # 计算性能指标
    avg_latency = np.mean(latencies)
    fps = 1000 / avg_latency
    avg_mem = np.mean(gpu_mems) if gpu_mems else 0
    avg_power = np.mean(gpu_powers) if gpu_powers else 0

    print("\n" + "="*60)
    print(f"TensorRT 评估报告")
    print("="*60)
    print(f"[分类性能]")
    print(f" Accuracy      : {acc:.2f}%")
    print(f" F1 Score      : {f1:.4f}")
    print("-" * 60)
    
    # === 打印误判详细列表 ===
    if len(misclassified_samples) > 0:
        print(f"\n[误判样本分析] 共发现 {len(misclassified_samples)} 个误判:")
        print("-" * 60)
        for sample in misclassified_samples:
            print(sample)
        print("-" * 60)
    else:
        print("\n[完美] 未发现误判样本！")
    # ============================

    print(f"\n[运行效率]")
    print(f" Avg Latency   : {avg_latency:.2f} ms")
    print(f" FPS           : {fps:.2f}")
    print(f" Avg GPU Power : {avg_power:.2f} W")
    print("="*60)
    
    print("\n分类报告:")
    print(classification_report(all_targets, all_preds, target_names=classes, digits=4))

def main():
    parser = argparse.ArgumentParser(description='EdgeDisNet TensorRT 验证脚本')
    parser.add_argument('--engine', type=str, required=True, help='Engine 文件路径')
    parser.add_argument('--data_root', type=str, default=str(Config.DATA_ROOT), help='数据集路径')
    args = parser.parse_args()

    input_size = 240 
    
    transform_val = transforms.Compose([
        transforms.Resize((input_size, input_size), interpolation=InterpolationMode.BICUBIC, antialias=True),
        transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
    ])
    
    print(f"数据集目录: {args.data_root}")
    if not os.path.exists(args.data_root):
        print(f"❌ 错误: 数据集路径不存在 {args.data_root}")
        return

    dataset = VideoDataset(args.data_root, transform=transform_val, num_frames=Config.HYPERPARAMS['num_frames'])
    
    classes = sorted([d.name for d in Path(args.data_root).iterdir() if d.is_dir()])
    print(f"类别列表: {classes}")
    
    loader = DataLoader(dataset, batch_size=1, shuffle=False, num_workers=0)

    if not os.path.exists(args.engine):
        raise FileNotFoundError(f"找不到 Engine 文件: {args.engine}")
        
    trt_model = TRTWrapper(args.engine)
    validate_trt(trt_model, loader, classes)

if __name__ == '__main__':
    main()