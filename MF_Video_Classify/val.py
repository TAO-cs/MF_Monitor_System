import torch
import torch.nn as nn
import numpy as np
import argparse
from pathlib import Path
from torch.utils.data import DataLoader
from torchvision import transforms
from torchvision.transforms.functional import InterpolationMode
from tqdm import tqdm
from sklearn.metrics import f1_score, precision_score, recall_score, confusion_matrix, classification_report
import cv2

# 从 EdgeDisNet.py 导入模型
from model.EdgeDisNet import edge_dis_net

# --- 1. 配置与参数 (保持与 train.py 一致) ---
class Config:
    BASE_DIR        = Path(__file__).resolve().parent
    DATA_ROOT       = BASE_DIR / 'Datasets'  # 验证数据目录
    
    # 这里必须与训练时的参数保持一致，否则权重无法加载
    HYPERPARAMS = {
        'num_classes':      2,
        'num_frames':       8,
        'batch_size':       16,
        'num_workers':      4,
        'reduction':        8,
        'width_coeff':      0.4,
        'depth_coeff':      0.3,
        'drop_connect_rate': 0.0, # 验证时不需要 drop connect
        'num_groups':       4,
        'dropout_p':        0.0   # 验证时不需要 dropout
    }

# --- 2. 视频数据集类 (复用 train.py) ---
class VideoDataset(torch.utils.data.Dataset):
    def __init__(self, root, transform=None, num_frames=8):
        self.root = Path(root)
        self.transform = transform
        self.num_frames = num_frames
        self.samples = self._make_dataset(self.root)
        if len(self.samples) == 0:
            raise RuntimeError(f"在 {self.root} 中未发现视频文件 (.avi)")

    def _make_dataset(self, directory):
        instances = []
        directory = Path(directory)
        # 假设目录结构: root/class_name/video.avi
        for target_class in sorted([d.name for d in directory.iterdir() if d.is_dir()]):
            class_dir = directory / target_class
            # 获取类别索引 (假设只有两类，字母顺序排序: flood=0, mudslide=1)
            # 这里的逻辑必须与 ImageFolder/DatasetFolder 默认逻辑一致
            class_to_idx = {cls_name: i for i, cls_name in enumerate(sorted([d.name for d in directory.iterdir() if d.is_dir()]))}
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
        # Pad if not enough frames
        while len(frames) < self.num_frames:
            frames.append(frames[-1])
        return torch.stack(frames)

    def __getitem__(self, index):
        path, target = self.samples[index]
        video = self.video_loader(path)
        if self.transform is not None:
            video = torch.stack([self.transform(frame) for frame in video])
        return video, target, str(path) # 返回路径方便分析坏样本

    def __len__(self):
        return len(self.samples)

# --- 3. 验证函数 ---
def validate(model, loader, device, classes):
    model.eval()
    all_preds = []
    all_targets = []
    
    print("正在进行推理...")
    with torch.no_grad():
        for data, target, paths in tqdm(loader):
            data, target = data.to(device), target.to(device)
            outputs = model(data)
            
            # 获取预测结果
            probs = torch.softmax(outputs, dim=1)
            preds = outputs.argmax(dim=1)
            
            all_preds.extend(preds.cpu().numpy())
            all_targets.extend(target.cpu().numpy())

    # --- 计算指标 ---
    all_preds = np.array(all_preds)
    all_targets = np.array(all_targets)
    
    # 1. 基础指标
    acc = (all_preds == all_targets).mean() * 100
    f1 = f1_score(all_targets, all_preds, average='weighted')
    precision = precision_score(all_targets, all_preds, average='weighted', zero_division=0)
    recall = recall_score(all_targets, all_preds, average='weighted', zero_division=0)
    
    print("\n" + "="*50)
    print(f"评估结果 summary:")
    print(f"Accuracy : {acc:.2f}%")
    print(f"F1 Score : {f1:.4f}")
    print(f"Precision: {precision:.4f}")
    print(f"Recall   : {recall:.4f}")
    print("="*50)

    # 2. 详细分类报告
    print("\n详细分类报告:")
    print(classification_report(all_targets, all_preds, target_names=classes, digits=4))
    
    # 3. 混淆矩阵
    cm = confusion_matrix(all_targets, all_preds)
    print("\n混淆矩阵 (Confusion Matrix):")
    print(f"{'':>10} | 预测 {classes[0]} | 预测 {classes[1]}")
    print("-" * 40)
    print(f"真实 {classes[0]:<5} | {cm[0][0]:^10} | {cm[0][1]:^10}")
    print(f"真实 {classes[1]:<5} | {cm[1][0]:^10} | {cm[1][1]:^10}")
    print("="*50)

# --- 4. 主函数 ---
def main():
    parser = argparse.ArgumentParser(description='EdgeDisNet 模型评估脚本')
    parser.add_argument('--checkpoint', type=str, required=True, help='模型 .pth 文件的路径')
    parser.add_argument('--data_root', type=str, default=str(Config.DATA_ROOT), help='数据集根目录')
    parser.add_argument('--batch_size', type=int, default=16, help='批量大小')
    args = parser.parse_args()

    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    print(f"使用设备: {device}")

    # 1. 准备数据
    # 仅使用验证集变换
    transform_val = transforms.Compose([
        transforms.Resize((240, 240), interpolation=InterpolationMode.BICUBIC, antialias=True),
        transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
    ])
    
    print(f"加载数据集: {args.data_root}")
    dataset = VideoDataset(args.data_root, transform=transform_val, num_frames=Config.HYPERPARAMS['num_frames'])
    
    # 获取类别名称
    # 这里的逻辑是扫描文件夹名字，通常是 ['flood', 'mudslide']
    classes = sorted([d.name for d in Path(args.data_root).iterdir() if d.is_dir()])
    print(f"检测到的类别: {classes}")
    
    loader = DataLoader(dataset, batch_size=args.batch_size, shuffle=False, num_workers=4, pin_memory=True)

    # 2. 初始化模型
    print("正在初始化模型...")
    model = edge_dis_net(
        num_classes=len(classes),
        dropout_rate=Config.HYPERPARAMS['dropout_p'],
        reduction=Config.HYPERPARAMS['reduction'],
        width_coeff=Config.HYPERPARAMS['width_coeff'],
        depth_coeff=Config.HYPERPARAMS['depth_coeff'],
        drop_connect_rate=Config.HYPERPARAMS['drop_connect_rate'],
        num_groups=Config.HYPERPARAMS['num_groups']
    ).to(device)

    # 3. 加载权重
    checkpoint_path = Path(args.checkpoint)
    if not checkpoint_path.exists():
        raise FileNotFoundError(f"找不到权重文件: {checkpoint_path}")

    print(f"加载权重: {checkpoint_path}")
    checkpoint = torch.load(checkpoint_path, map_location=device)
    
    # 处理 checkpoint 里的 key
    if 'state_dict' in checkpoint:
        state_dict = checkpoint['state_dict']
    else:
        state_dict = checkpoint # 有些时候直接保存的是 state_dict

    # 处理 DataParallel 带来的 'module.' 前缀
    new_state_dict = {}
    for k, v in state_dict.items():
        if k.startswith('module.'):
            new_state_dict[k[7:]] = v # 去掉 'module.'
        else:
            new_state_dict[k] = v
            
    model.load_state_dict(new_state_dict)
    print("权重加载成功！")

    # 4. 开始验证
    validate(model, loader, device, classes)

if __name__ == '__main__':
    main()