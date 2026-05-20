import random
import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
import torch.optim.lr_scheduler as lr_scheduler
import logging
from datetime import datetime
from pathlib import Path
from torch.utils.data import DataLoader, WeightedRandomSampler, Subset
from torchvision import datasets, transforms, io
from torchvision.transforms.functional import InterpolationMode
from tqdm import tqdm
from sklearn.metrics import f1_score, precision_score, recall_score
from thop import profile
import time
from torch.amp import GradScaler, autocast
from sklearn.model_selection import StratifiedKFold  # 导入 K-Fold
import cv2                                             # 导入 OpenCV 用于高效视频采样

# 从 EdgeDisNet.py 导入模型
from model.EdgeDisNet import edge_dis_net

# 配置类
class Config:
    """训练配置类，定义路径和超参数"""
    BASE_DIR        = Path('/root/autodl-tmp')                                # 基础目录
    DATA_ROOT       = Path(BASE_DIR /'/root/autodl-tmp/Datasets')        # 数据集目录 (现在指向包含所有类的根目录)
    LOG_DIR         = Path('/root/autodl-fs/MF2_Video/MF2_EdgeDisNet_logs')  # 日志目录
    CHECKPOINT_DIR  = LOG_DIR / 'MF2_Video/checkpoints'                    # 检查点目录

    HYPERPARAMS = {
        'batch_size':       16,                                 # 批量大小
        'num_classes':      2,                                  # 类别数
        'max_epochs':       100,                                # 最大训练轮数
        'learning_rate':    1e-4,                               # 初始学习率
        'weight_decay':     1e-5,                               # 权重衰减
        'seed':             42,                                 # 随机种子
        'num_workers':      8,                                  # 数据加载线程数
        'use_checkpoint':   True,                               # 是否保存检查点
        'checkpoint_interval': 5,                               # 检查点保存间隔
        'dropout_p':        0.3,                                # Dropout 概率
        'warmup_epochs':    5,                                  # Warmup 周期
        'use_amp':          True,                               # 使用混合精度训练
        'multi_runs':       5,                                  # 多轮运行次数
        'enable_multi_runs': True,                              # 是否启用多轮运行
        'reduction':        8,                                  # 降维比例
        'width_coeff':      0.4,                                # 宽度缩放系数
        'depth_coeff':      0.3,                                # 深度缩放系数
        'drop_connect_rate': 0.05,                              # DropConnect 概率
        'num_groups':       4,                                  # 分组注意力组数
        'early_stop_patience': 15,                              # 早停耐心值
        'mixup_alpha':      0.8,                                # Mixup alpha 参数
        'cutmix_alpha':     1.0,                                # CutMix alpha 参数
        'mixup_prob':       0.3,                                # Mixup 应用概率
        'cutmix_prob':      0.3,                                # CutMix 应用概率
        'lr_reduce_factor': 0.975,                              # 学习率衰减因子
        'lr_reduce_patience': 4,                                # 学习率衰减周期
        'num_frames':       8,                                  # 视频帧数
        'k_folds':          5,                                  # 交叉验证折数
        'train_models': [                                       # 训练模型列表
            'EdgeDisNet'
        ]
    }

# 日志模块
def setup_logging(log_dir, timestamp, model_name):
    """设置日志记录，保存到文件并输出到控制台"""
    log_dir.mkdir(parents=True, exist_ok=True)                  # 创建日志目录
    log_file = log_dir / f'train_{model_name}_{timestamp}.log' # 日志文件名
    logger = logging.getLogger(f'main_{model_name}')           # 创建日志器
    logger.setLevel(logging.INFO)                              # 设置日志级别
    logger.propagate = False                                   # 禁用日志传播
    file_handler = logging.FileHandler(log_file)               # 文件处理器
    file_handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))  # 设置日志格式
    console_handler = logging.StreamHandler()                  # 控制台处理器
    console_handler.setLevel(logging.INFO)                     # 设置控制台日志级别
    console_handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))  # 设置控制台日志格式
    logger.handlers = [file_handler, console_handler]          # 添加处理器
    return logger                                              # 返回日志器

def log_message(logger, message, level='info'):
    """记录日志消息，支持不同级别"""
    getattr(logger, level.lower(), logger.info)(message)       # 动态调用日志级别方法

# 工具函数
def set_seed(seed):
    """设置随机种子，确保实验可重复"""
    random.seed(seed)                                          # 设置 Python 随机种子
    np.random.seed(seed)                                       # 设置 NumPy 随机种子
    torch.manual_seed(seed)                                    # 设置 PyTorch 随机种子
    torch.cuda.manual_seed_all(seed)                           # 设置 CUDA 随机种子
    torch.backends.cudnn.deterministic = True                  # 确保确定性计算
    torch.backends.cudnn.benchmark = True                      # 启用性能优化

# 数据增强
def get_transforms():
    """定义训练和验证的数据增强变换"""
    transform_train = transforms.Compose([
        transforms.RandomResizedCrop(240, scale=(0.7, 1.0), antialias=True), # 随机裁剪并调整大小到240x240
        transforms.RandomHorizontalFlip(p=0.5),              # 随机水平翻转，概率0.5
        transforms.RandomRotation(30),                       # 随机旋转 [-30°, 30°]
        transforms.ColorJitter(brightness=0.3, contrast=0.3, saturation=0.3),  # 颜色偏移
        transforms.GaussianBlur(kernel_size=3, sigma=(0.1, 2.0)),  # 随机高斯模糊
        transforms.RandomAffine(degrees=0, translate=(0.1, 0.1)),  # 随机平移
        transforms.RandomAffine(degrees=0, scale=(0.8, 1.2)),# 随机缩放
        transforms.RandomErasing(p=0.3, scale=(0.02, 0.33), ratio=(0.3, 3.3)),  # 随机擦除
        transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])  # 归一化
    ])
    transform_val = transforms.Compose([
        transforms.Resize((240, 240), interpolation=InterpolationMode.BICUBIC, antialias=True),  # 调整大小到240x240
        transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])  # 归一化
    ])
    return transform_train, transform_val                    # 返回训练和验证变换

# 视频数据集类
class VideoDataset(datasets.DatasetFolder):
    """视频数据集类，用于加载视频文件"""
    def __init__(self, root, transform=None, num_frames=8):
        super().__init__(root, loader=self.video_loader, extensions=('avi',))
        self.transform = transform
        self.num_frames = num_frames

    def video_loader(self, path):
        """加载视频文件 (使用 cv2 高效采样帧，修复内存错误)"""
        cap = cv2.VideoCapture(str(path))                      # 打开视频文件
        frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))   # 获取总帧数
        if frame_count <= 0:
            cap.release()
            raise ValueError(f"无法读取视频: {path}")
        
        # 均匀采样索引
        indices = np.linspace(0, frame_count - 1, self.num_frames, dtype=int)
        
        frames = []
        for idx in indices:
            cap.set(cv2.CAP_PROP_POS_FRAMES, idx)              # 设置帧位置
            ret, frame = cap.read()                            # 读取帧
            if ret:
                frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB) # 转换为 RGB
                frame = torch.from_numpy(frame).permute(2, 0, 1).float() / 255.0  # 转换为张量
                frames.append(frame)
            else:
                # 如果读取失败，使用前一帧或处理错误
                if frames:
                    frames.append(frames[-1])
                else:
                    raise ValueError(f"无法读取帧 {idx} 在 {path}")
        
        cap.release()                                          # 释放捕获器
        video = torch.stack(frames)                            # 堆叠为 (T, C, H, W)
        return video

    def __getitem__(self, index):
        """获取数据集项"""
        path, target = self.samples[index]
        video = self.loader(path)
        if self.transform is not None:
            # 应用变换到视频的每一帧
            video = torch.stack([self.transform(frame) for frame in video])
        return video, target

# CutMix 数据增强
def cutmix(data, targets, alpha=1.0):
    """CutMix 数据增强"""
    indices = torch.randperm(data.size(0))
    shuffled_targets = targets[indices]
    lam = np.random.beta(alpha, alpha)
    bbx1, bby1, bbx2, bby2 = rand_bbox(data.size()[3:], lam) # 调整以适应 5D 张量
    data[..., bby1:bby2, bbx1:bbx2] = data[indices, ..., bby1:bby2, bbx1:bbx2]
    return data, targets, shuffled_targets, lam

def rand_bbox(size, lam):
    """生成 CutMix 的随机边界框"""
    H = size[0] # 高度在索引 0
    W = size[1] # 宽度在索引 1
    cut_rat = np.sqrt(1. - lam)
    cut_w = int(W * cut_rat)
    cut_h = int(H * cut_rat)
    cx = np.random.randint(W)
    cy = np.random.randint(H)
    bbx1 = np.clip(cx - cut_w // 2, 0, W)
    bby1 = np.clip(cy - cut_h // 2, 0, H)
    bbx2 = np.clip(cx + cut_w // 2, 0, W)
    bby2 = np.clip(cy + cut_h // 2, 0, H)
    return bbx1, bby1, bbx2, bby2

# Mixup 数据增强
def mixup(data, targets, alpha=0.8):
    """Mixup 数据增强"""
    indices = torch.randperm(data.size(0))
    shuffled_data = data[indices]
    shuffled_targets = targets[indices]
    lam = np.random.beta(alpha, alpha)
    data = lam * data + (1 - lam) * shuffled_data
    return data, targets, shuffled_targets, lam

# 计算 Top-k 准确率
def calculate_topk_accuracy(outputs, targets, k=1):
    """计算 Top-k 准确率"""
    with torch.no_grad():
        _, pred = outputs.topk(k, dim=1, largest=True, sorted=True)  # 获取 Top-k 预测
        pred = pred.t()                                        # 转置预测结果
        correct = pred.eq(targets.view(1, -1).expand_as(pred)) # 计算正确预测
        correct_k = correct[:k].reshape(-1).float().sum(0, keepdim=True)  # 计算 Top-k 正确数
        return correct_k.mul_(100.0 / targets.size(0))        # 返回 Top-k 准确率

# 计算评估指标
def calculate_metrics(outputs, targets, average='weighted'):
    """计算 F1 分数、精确率和召回率"""
    preds = outputs                        # 获取预测类别
    f1 = f1_score(targets.cpu().numpy(), preds.cpu().numpy(), average=average)  # 计算 F1 分数
    precision = precision_score(targets.cpu().numpy(), preds.cpu().numpy(), average=average, zero_division=0)  # 计算精确率
    recall = recall_score(targets.cpu().numpy(), preds.cpu().numpy(), average=average, zero_division=0)  # 计算召回率
    return f1, precision, recall                               # 返回评估指标

# 计算参数量和 FLOPs
def calculate_model_metrics(model, num_frames, device):
    """计算模型参数量和 FLOPs"""
    total_params = sum(p.numel() for p in model.parameters())   # 计算总参数量
    # 创建 5D 输入张量 (batch, time, channels, height, width)
    input_tensor = torch.randn(1, num_frames, 3, 240, 240).to(device)
    flops, _ = profile(model, inputs=(input_tensor,), verbose=False)  # 计算 FLOPs
    return total_params, flops / 1e6                           # 返回参数量（M）和 FLOPs（M）

# 计算推理时间
def calculate_inference_time(model, num_frames, batch_size=32, num_runs=100, device='cuda'):
    """计算模型推理时间"""
    model.eval()                                               # 设置模型为评估模式
    # 创建 5D 批量输入张量
    input_tensor = torch.randn(batch_size, num_frames, 3, 240, 240).to(device)
    total_time = 0.0                                           # 初始化总时间
    with torch.no_grad():
        for _ in range(num_runs):
            start_time = time.time()                           # 记录开始时间
            _ = model(input_tensor)                            # 推理
            torch.cuda.synchronize()                           # 同步 CUDA
            total_time += time.time() - start_time             # 累加时间
    return total_time / num_runs                               # 返回平均推理时间

# 自定义阶梯学习率调度器
class StepLRScheduler:
    """自定义阶梯学习率调度器"""
    def __init__(self, optimizer, step_size=4, gamma=0.975):
        self.optimizer = optimizer                             # 优化器
        self.step_size = step_size                             # 步长
        self.gamma = gamma                                     # 衰减因子
        self.last_epoch = -1                                   # 上一个 epoch

    def step(self, epoch=None):
        """更新学习率"""
        if epoch is None:
            epoch = self.last_epoch + 1                        # 更新 epoch
        self.last_epoch = epoch                                # 保存当前 epoch
        if (epoch + 1) % self.step_size == 0:
            for param_group in self.optimizer.param_groups:
                param_group['lr'] *= self.gamma                # 衰减学习率

# 训练一个 epoch
def train_epoch(model, loader, criterion, optimizer, scaler, device, use_amp, epoch, cfg):
    """训练一个 epoch"""
    model.train()                                              # 设置模型为训练模式
    running_loss = 0.0                                         # 初始化运行损失
    correct = 0                                                # 初始化正确预测数
    total = 0                                                  # 初始化总样本数
    all_preds = []                                             # 初始化所有预测
    all_targets = []                                           # 初始化所有目标

    for batch_idx, (data, target) in enumerate(tqdm(loader, desc=f'Training Epoch {epoch + 1}')):
        data, target = data.to(device), target.to(device)      # 移动到设备
        optimizer.zero_grad()                                  # 清零梯度

        if random.random() < cfg.HYPERPARAMS['mixup_prob']:    # 应用 Mixup
            data, target_a, target_b, lam = mixup(data, target, cfg.HYPERPARAMS['mixup_alpha'])
        elif random.random() < cfg.HYPERPARAMS['cutmix_prob']: # 应用 CutMix
            data, target_a, target_b, lam = cutmix(data, target, cfg.HYPERPARAMS['cutmix_alpha'])
        else:
            target_a, target_b, lam = target, None, None       # 无增强

        with autocast(device_type=device.type, enabled=use_amp):                        # 混合精度上下文
            outputs = model(data)                              # 前向传播
        
        outputs = outputs.float()

        if target_b is not None:                               # 计算增强损失
            loss = lam * criterion(outputs, target_a) + (1 - lam) * criterion(outputs, target_b)
        else:
            loss = criterion(outputs, target_a)                 # 计算标准损失

        scaler.scale(loss).backward()                          # 反向传播
        scaler.step(optimizer)                                 # 更新参数
        scaler.update()                                        # 更新 scaler

        running_loss += loss.item()                            # 累加损失
        total += target.size(0)                                # 累加样本数
        correct += calculate_topk_accuracy(outputs, target)[0].item() * target.size(0) / 100  # 累加正确预测
        all_preds.append(outputs.argmax(dim=1).cpu().numpy())  # 收集预测
        all_targets.append(target.cpu().numpy())                # 收集目标

    avg_loss = running_loss / len(loader)                      # 计算平均损失
    top1_acc = (correct / total) * 100                         # 计算 Top-1 准确率
    all_preds = np.concatenate(all_preds)                      # 合并预测
    all_targets = np.concatenate(all_targets)                  # 合并目标
    f1, precision, recall = calculate_metrics(torch.tensor(all_preds), torch.tensor(all_targets))  # 计算指标

    return avg_loss, top1_acc, f1, precision, recall           # 返回训练指标

# 验证一个 epoch
def validate_epoch(model, loader, criterion, device, use_amp):
    """验证一个 epoch"""
    model.eval()                                               # 设置模型为评估模式
    running_loss = 0.0                                         # 初始化运行损失
    correct = 0                                                # 初始化正确预测数
    total = 0                                                  # 初始化总样本数
    all_preds = []                                             # 初始化所有预测
    all_targets = []                                           # 初始化所有目标

    with torch.no_grad():                                      # 无梯度上下文
        for data, target in tqdm(loader, desc='Validating'):
            data, target = data.to(device), target.to(device)  # 移动到设备
            with autocast(device_type=device.type, enabled=use_amp):                    # 混合精度上下文
                outputs = model(data)                          # 前向传播
            outputs = outputs.float()                          # 转换为 float 类型
            loss = criterion(outputs, target)                  # 计算损失
            running_loss += loss.item()                        # 累加损失
            total += target.size(0)                            # 累加样本数
            correct += calculate_topk_accuracy(outputs, target)[0].item() * target.size(0) / 100  # 累加正确预测
            all_preds.append(outputs.argmax(dim=1).cpu().numpy())  # 收集预测
            all_targets.append(target.cpu().numpy())            # 收集目标

    avg_loss = running_loss / len(loader)                      # 计算平均损失
    top1_acc = (correct / total) * 100                         # 计算 Top-1 准确率
    all_preds = np.concatenate(all_preds)                      # 合并预测
    all_targets = np.concatenate(all_targets)                  # 合并目标
    f1, precision, recall = calculate_metrics(torch.tensor(all_preds), torch.tensor(all_targets))  # 计算指标

    return avg_loss, top1_acc, f1, precision, recall           # 返回验证指标

# 主函数
def main():
    """主函数，执行训练流程"""
    cfg = Config()                                             # 初始化配置
    
    # 修复时间戳 (FileNotFoundError)
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')       # 获取时间戳
    
    # 自动检测并使用 GPU
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')  # 选择设备
    
    cfg.LOG_DIR.mkdir(parents=True, exist_ok=True)            # 创建日志目录
    cfg.CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)     # 创建检查点目录
    
    # 设置一个全局日志（用于 K-Fold 循环外部）
    global_logger = setup_logging(cfg.LOG_DIR, f'{timestamp}_main', 'global')
    log_message(global_logger, f'日志目录: {cfg.LOG_DIR}, 检查点目录: {cfg.CHECKPOINT_DIR}')
    log_message(global_logger, f'正在使用设备: {device}')         # 明确告知用户正在使用什么设备

    if not cfg.DATA_ROOT.exists():
        log_message(global_logger, f'数据集目录 {cfg.DATA_ROOT} 不存在', level='error')  # 记录数据集错误
        raise FileNotFoundError(f'数据集目录 {cfg.DATA_ROOT} 不存在')  # 抛出异常

    model_map = {
        'EdgeDisNet':       edge_dis_net,                    # EdgeDisNet 模型映射
    }

    train_models = cfg.HYPERPARAMS['train_models']             # 获取训练模型列表
    if not train_models:
        log_message(global_logger, '未指定训练模型，退出', level='error')  # 记录模型错误
        raise ValueError('HYPERPARAMS["train_models"] 不能为空')  # 抛出异常

    for model_name in train_models:
        if model_name not in model_map:
            log_message(global_logger, f'无效模型名称: {model_name}', level='error')  # 记录无效模型
            raise ValueError(f'模型 {model_name} 不在支持列表 {list(model_map.keys())}')  # 抛出异常

    # 获取数据变换
    transform_train, transform_val = get_transforms()

    # 创建两个完整的数据集实例：一个用于训练（带增强），一个用于验证（不带增强）
    # 它们共享相同的样本索引，但应用不同的变换
    dataset_for_train = VideoDataset(cfg.DATA_ROOT, transform=transform_train, num_frames=cfg.HYPERPARAMS['num_frames'])
    dataset_for_val = VideoDataset(cfg.DATA_ROOT, transform=transform_val, num_frames=cfg.HYPERPARAMS['num_frames'])
    
    # 获取所有样本的目标（标签）用于分层 K-Fold
    # .samples 格式为 [(file_path, label), ...]
    try:
        targets = [s[1] for s in dataset_for_train.samples]
        if not targets:
            raise ValueError("未在 {cfg.DATA_ROOT} 中找到样本。")
    except Exception as e:
        log_message(global_logger, f"加载数据集样本时出错: {e}", level='error')
        return

    # 初始化 K-Fold
    skf = StratifiedKFold(n_splits=cfg.HYPERPARAMS['k_folds'], 
                          shuffle=True, 
                          random_state=cfg.HYPERPARAMS['seed'])

    for model_name in train_models:
        model_class = model_map[model_name]                    # 获取模型类
        num_runs = cfg.HYPERPARAMS['multi_runs'] if cfg.HYPERPARAMS['enable_multi_runs'] else 1  # 获取运行次数
        
        for run in range(num_runs):
            set_seed(cfg.HYPERPARAMS['seed'] + run)           # 设置随机种子
            run_timestamp = f'{timestamp}_run{run + 1}'
            
            fold_results = [] # 存储每折的最佳 F1 分数

            log_message(global_logger, f'开始第 {run + 1} 次运行 {model_name}')

            # K-Fold 交叉验证循环
            for fold, (train_indices, val_indices) in enumerate(skf.split(np.zeros(len(targets)), targets)):
                fold_num = fold + 1
                logger = setup_logging(cfg.LOG_DIR, f'{run_timestamp}_fold{fold_num}', model_name)  # 为此折设置日志
                log_message(logger, f'--- 开始 K-Fold 第 {fold_num} / {cfg.HYPERPARAMS["k_folds"]} 折 ---')

                # 1. 创建 Subset
                train_subset = Subset(dataset_for_train, train_indices)
                val_subset = Subset(dataset_for_val, val_indices)

                # 2. 为当前折的训练集创建加权采样器
                # 提取当前训练子集的标签
                train_targets = [targets[i] for i in train_indices] 
                class_counts = np.bincount(train_targets, minlength=cfg.HYPERPARAMS['num_classes'])
                class_weights = 1. / (torch.tensor(class_counts, dtype=torch.float32) + 1e-6)
                sample_weights = [class_weights[label] for label in train_targets]
                sampler = WeightedRandomSampler(sample_weights, len(train_subset))

                # 3. 创建 DataLoader
                train_loader = DataLoader(train_subset, batch_size=cfg.HYPERPARAMS['batch_size'], sampler=sampler,
                                      num_workers=cfg.HYPERPARAMS['num_workers'], pin_memory=True, persistent_workers=True)
                val_loader = DataLoader(val_subset, batch_size=cfg.HYPERPARAMS['batch_size'], shuffle=False,
                                    num_workers=cfg.HYPERPARAMS['num_workers'], pin_memory=True, persistent_workers=True)

                log_message(logger, f'训练集大小: {len(train_subset)}, 验证集大小: {len(val_subset)}')
                log_message(logger, f'类别权重: {class_weights.numpy().tolist()}')

                # 4. 初始化模型、损失、优化器等（每折都重新初始化）
                criterion = nn.CrossEntropyLoss(weight=class_weights.to(device))  # 加权交叉熵损失

                model = model_class(
                    num_classes=cfg.HYPERPARAMS['num_classes'],
                    dropout_rate=cfg.HYPERPARAMS['dropout_p'],
                    reduction=cfg.HYPERPARAMS['reduction'],
                    width_coeff=cfg.HYPERPARAMS['width_coeff'],
                    depth_coeff=cfg.HYPERPARAMS['depth_coeff'],
                    drop_connect_rate=cfg.HYPERPARAMS['drop_connect_rate'],
                    num_groups=cfg.HYPERPARAMS['num_groups']
                ).to(device)

                pretrained_path = Path('F:\\graduation\\AIDERv2_EdgeDisNet_logs\\checkpoints\\best_model_EdgeDisNet.pth')
                if pretrained_path.exists():
                    try:
                        checkpoint = torch.load(pretrained_path, map_location=device)
                        model.load_state_dict(checkpoint['state_dict'], strict=False)
                        log_message(logger, f'加载预训练权重从 {pretrained_path}')
                    except Exception as e:
                        log_message(logger, f'加载预训练权重失败: {e}', level='warning')

                if torch.cuda.device_count() > 1:                          # 支持多 GPU
                    model = nn.DataParallel(model)                         # 包装为 DataParallel
                    log_message(logger, f'使用 {torch.cuda.device_count()} 个 GPU')  # 记录 GPU 数量

                # 在模型并行化 (DataParallel) 之后计算指标
                params, flops = calculate_model_metrics(model, cfg.HYPERPARAMS['num_frames'], device)
                log_message(logger, f'{model_name} 参数量: {params}，FLOPs: {flops:.2f}M')  # 记录模型指标

                inference_time = calculate_inference_time(model, cfg.HYPERPARAMS['num_frames'], batch_size=cfg.HYPERPARAMS['batch_size'], device=device)
                log_message(logger, f'{model_name} 推理时间 ({cfg.HYPERPARAMS["batch_size"]} images): {inference_time:.4f}s')  # 记录推理时间

                optimizer = optim.RMSprop(model.parameters(), lr=cfg.HYPERPARAMS['learning_rate'],
                                          momentum=0.9, weight_decay=cfg.HYPERPARAMS['weight_decay'], alpha=0.9)  # 初始化 RMSProp 优化器
                scheduler = StepLRScheduler(optimizer, step_size=cfg.HYPERPARAMS['lr_reduce_patience'],
                                            gamma=cfg.HYPERPARAMS['lr_reduce_factor'])  # 初始化阶梯学习率调度器
                scaler = GradScaler(enabled=cfg.HYPERPARAMS['use_amp'])    # 初始化混合精度 scaler

                best_val_f1 = 0.0                                         # 初始化最佳验证 F1 分数
                best_model_path = cfg.CHECKPOINT_DIR / f'best_model_{model_name}_fold{fold_num}.pth'  # 最佳模型路径（包含折编号）
                early_stop_counter = 0                                    # 早停计数器
                metrics_history = {
                    'train_loss': [], 'val_loss': [],
                    'train_top1': [], 'val_top1': [],
                    'train_f1': [], 'val_f1': [],
                    'train_precision': [], 'val_precision': [],
                    'train_recall': [], 'val_recall': []
                }                                                         # 初始化指标历史

                # 5. Epoch 训练循环
                for epoch in range(cfg.HYPERPARAMS['max_epochs']):
                    scheduler.step(epoch)                                  # 应用阶梯学习率调度器
                    log_message(logger, f'Epoch {epoch + 1} 学习率: {optimizer.param_groups[0]["lr"]:.6f}')  # 记录当前学习率
                    train_metrics = train_epoch(model, train_loader, criterion, optimizer, scaler, device, cfg.HYPERPARAMS['use_amp'], epoch, cfg)  # 训练一个 epoch
                    val_metrics = validate_epoch(model, val_loader, criterion, device, cfg.HYPERPARAMS['use_amp'])  # 验证一个 epoch
                    train_loss, train_top1, train_f1, train_precision, train_recall = train_metrics
                    val_loss, val_top1, val_f1, val_precision, val_recall = val_metrics

                    metrics_history['train_loss'].append(train_loss)       # 记录训练损失
                    metrics_history['val_loss'].append(val_loss)           # 记录验证损失
                    metrics_history['train_top1'].append(train_top1)       # 记录训练 Top-1
                    metrics_history['val_top1'].append(val_top1)           # 记录验证 Top-1
                    metrics_history['train_f1'].append(train_f1)           # 记录训练 F1
                    metrics_history['val_f1'].append(val_f1)               # 记录验证 F1
                    metrics_history['train_precision'].append(train_precision)  # 记录训练精确率
                    metrics_history['val_precision'].append(val_precision) # 记录验证精确率
                    metrics_history['train_recall'].append(train_recall)   # 记录训练召回率
                    metrics_history['val_recall'].append(val_recall)       # 记录验证召回率

                    log_message(logger, f'Epoch {epoch + 1} Train Loss: {train_loss:.4f}, Val Loss: {val_loss:.4f}, Loss Gap: {train_loss - val_loss:.4f}')  # 记录损失
                    log_message(logger, f'Epoch {epoch + 1} Train Top-1: {train_top1:.2f}%, Val Top-1: {val_top1:.2f}%')  # 记录 Top-1
                    log_message(logger, f'Epoch {epoch + 1} Train F1: {train_f1:.4f}, Val F1: {val_f1:.4f}')  # 记录 F1 分数
                    log_message(logger, f'Epoch {epoch + 1} Train Precision: {train_precision:.4f}, Val Precision: {val_precision:.4f}')  # 记录精确率
                    log_message(logger, f'Epoch {epoch + 1} Train Recall: {train_recall:.4f}, Val Recall: {val_recall:.4f}')  # 记录召回率

                    if cfg.HYPERPARAMS['use_checkpoint'] and (epoch + 1) % cfg.HYPERPARAMS['checkpoint_interval'] == 0:
                        checkpoint_path = cfg.CHECKPOINT_DIR / f'checkpoint_epoch_{epoch + 1}_{model_name}_fold{fold_num}.pth'  # 检查点路径
                        torch.save({
                            'state_dict': model.state_dict(),                 # 保存模型状态
                            'metrics': { 'epoch': epoch + 1, 'val_f1': val_f1, 'val_loss': val_loss }
                        }, checkpoint_path)
                        log_message(logger, f'保存检查点: {checkpoint_path}')  # 记录检查点保存

                    if val_f1 > best_val_f1:                              # 基于最佳 F1 保存模型
                        best_val_f1 = val_f1                              # 更新最佳验证 F1 分数
                        early_stop_counter = 0                            # 重置早停计数器
                        torch.save({
                            'state_dict': model.state_dict(),              # 保存模型状态
                            'metrics': {
                                'epoch': epoch + 1, 'train_loss': train_loss, 'val_loss': val_loss,
                                'train_top1': train_top1, 'val_top1': val_top1, 'train_f1': train_f1,
                                'val_f1': val_f1, 'train_precision': train_precision, 'val_precision': val_precision,
                                'train_recall': train_recall, 'val_recall': val_recall
                            }
                        }, best_model_path)
                        log_message(logger, f'更新最佳模型，Val F1: {val_f1:.4f}, Val Top-1: {val_top1:.2f}%')  # 记录最佳模型
                    else:
                        early_stop_counter += 1                           # 增加早停计数器
                        if early_stop_counter >= cfg.HYPERPARAMS['early_stop_patience']:
                            log_message(logger, f'早停触发，连续 {early_stop_counter} 个 epoch 未提升，停止训练')  # 记录早停
                            break
                
                # 单折训练结束
                log_message(logger, f'--- 第 {fold_num} 折训练完成 ---')
                log_message(logger, f'此折最佳 Val F1: {best_val_f1:.4f}')
                fold_results.append(best_val_f1)
            
            # K-Fold 循环结束
            log_message(global_logger, f'--- {model_name} 第 {run + 1} 次运行 K-Fold 交叉验证完成 ---')
            if fold_results:
                avg_f1 = np.mean(fold_results)
                std_f1 = np.std(fold_results)
                log_message(global_logger, f'所有折的最佳 Val F1 列表: {[round(f, 4) for f in fold_results]}')
                log_message(global_logger, f'平均 Val F1: {avg_f1:.4f} +/- {std_f1:.4f}')
            
            log_message(global_logger, f'第 {run + 1} 次运行完成')

if __name__ == '__main__':
    main()                                                    # 执行主函数