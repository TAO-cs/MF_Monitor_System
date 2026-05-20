import sys
import os
import torch
import torch.nn as nn

# 将上级目录加入系统路径，以便导入 model 模块
current_dir = os.path.dirname(os.path.abspath(__file__))
parent_dir = os.path.dirname(current_dir)
sys.path.append(parent_dir)

from model.EdgeDisNet import edge_dis_net

def export_to_onnx():
    # ================= 模型配置参数 (源自 train.py Config 类) =================
    # 类别数量
    NUM_CLASSES = 2
    # 宽度缩放系数
    WIDTH_COEFF = 0.4
    # 深度缩放系数
    DEPTH_COEFF = 0.3
    # Dropout 概率
    DROPOUT_RATE = 0.3
    # 降维比例
    REDUCTION = 8
    # DropConnect 概率 (推理阶段通常不生效，但保持结构一致性)
    DROP_CONNECT_RATE = 0.05
    # 分组注意力组数
    NUM_GROUPS = 4
    
    # ================= 输入数据配置 =================
    # 视频帧数
    INPUT_FRAMES = 8
    # 输入图像的高度和宽度 (train.py 中验证集 Resize 为 240)
    INPUT_SIZE = 240
    
    # ================= 路径配置 =================
    # 权重文件路径
    pth_path = os.path.join(r"F:\graduation\best_model_EdgeDisNet.pth")
    # ONNX 输出路径
    onnx_path = os.path.join(r"D:\python_project\MF_Video_Classify\onnx_project\onnx\EdgeDisNet.onnx")

    # ================= 模型初始化 =================
    print(f"初始化模型结构: Width={WIDTH_COEFF}, Depth={DEPTH_COEFF}, Groups={NUM_GROUPS}, Size={INPUT_SIZE}")
    
    # 实例化模型，参数必须与训练脚本完全对应
    model = edge_dis_net(
        num_classes=NUM_CLASSES,
        dropout_rate=DROPOUT_RATE,
        reduction=REDUCTION,
        width_coeff=WIDTH_COEFF,
        depth_coeff=DEPTH_COEFF,
        drop_connect_rate=DROP_CONNECT_RATE,
        num_groups=NUM_GROUPS
    )

    # ================= 权重加载 =================
    print(f"从 {pth_path} 加载权重参数...")
    
    if not os.path.exists(pth_path):
        print(f"错误: 文件 {pth_path} 不存在")
        return

    try:
        # 加载检查点文件，映射至 CPU
        checkpoint = torch.load(pth_path, map_location='cpu')
        
        # 提取模型状态字典
        if 'state_dict' in checkpoint:
            state_dict = checkpoint['state_dict']
        else:
            state_dict = checkpoint
            
        # 移除 'module.' 前缀 (处理 DataParallel 保存的权重)
        new_state_dict = {}
        for k, v in state_dict.items():
            name = k.replace("module.", "")
            new_state_dict[name] = v
        
        # 加载参数至模型，strict=False 用于忽略训练过程中保存的额外统计量(如 total_ops)
        model.load_state_dict(new_state_dict, strict=False)
        print("权重加载完成")
        
    except Exception as e:
        print(f"权重加载过程中发生异常: {e}")
        return

    # ================= 模型导出 =================
    # 切换至评估模式 (影响 BatchNorm 和 Dropout 行为)
    model.eval()

    # 创建虚拟输入张量，形状为 (Batch, Time, Channel, Height, Width)
    dummy_input = torch.randn(1, INPUT_FRAMES, 3, INPUT_SIZE, INPUT_SIZE)

    print("开始导出 ONNX 模型...")
    try:
        torch.onnx.export(
            model,
            dummy_input,
            onnx_path,
            export_params=True,        # 导出训练好的参数权重
            opset_version=11,          # 设置 Opset 版本，11 对 TensorRT 兼容性较好
            do_constant_folding=True,  # 执行常量折叠优化
            input_names=['input'],     # 定义输入节点名称
            output_names=['output'],   # 定义输出节点名称
            dynamic_axes={             # 设置动态维度
                'input': {0: 'batch_size'},  # 允许批量大小可变
                'output': {0: 'batch_size'}
            }
        )
        print(f"导出成功: {onnx_path}")
        
    except Exception as e:
        print(f"导出 ONNX 失败: {e}")

if __name__ == "__main__":
    export_to_onnx()