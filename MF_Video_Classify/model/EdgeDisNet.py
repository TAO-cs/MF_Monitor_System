import torch
import torch.nn as nn
from typing import List, Optional
from torch import Tensor
import time
try:
    from torchprofile import profile_macs
except ImportError:
    profile_macs = None


class Hardswish(nn.Module):
    def __init__(self, inplace=False):
        super().__init__()
        self.inplace = inplace  
    def forward(self, x):
        return x * torch.clamp(x + 3, min=0, max=6) / 6  


def _make_divisible(v: float, divisor: int, min_value: Optional[int] = None) -> int:
    if min_value is None:
        min_value = divisor
    new_v = max(min_value, int(v + divisor / 2) // divisor * divisor)
    if new_v < 0.9 * v:
        new_v += divisor
    return new_v


class OptimizedAttention(nn.Module):
    def __init__(self, channels: int, reduction: int, num_groups: int = 2):
        super().__init__()
        self.num_groups = num_groups  
        self.group_size = channels // num_groups  
        self.avg_pool = nn.AdaptiveAvgPool2d(1)  
        self.fc1_list = nn.ModuleList([
            nn.Linear(self.group_size, self.group_size // reduction) for _ in range(num_groups)
        ])  
        self.fc2_list = nn.ModuleList([
            nn.Linear(self.group_size // reduction, self.group_size) for _ in range(num_groups)
        ])  
        self.relu = nn.ReLU6(inplace=True)  
        self.sigmoid = nn.Sigmoid()  

    def forward(self, x: Tensor) -> Tensor:
        batch_size, channels, _, _ = x.size()
        y = self.avg_pool(x).view(batch_size, channels)  
        y_groups = y.view(batch_size, self.num_groups, self.group_size)  
        attention = []
        for i in range(self.num_groups):
            group_y = y_groups[:, i]  
            group_y = self.fc1_list[i](group_y)  
            group_y = self.relu(group_y)
            group_y = self.fc2_list[i](group_y)  
            group_y = self.sigmoid(group_y)
            attention.append(group_y)
        y = torch.cat(attention, dim=1).view(batch_size, channels, 1, 1)  
        return x * y  


class ConvBNActivation(nn.Sequential):
    def __init__(self, in_channels: int, out_channels: int, kernel_size: int, stride: int = 1,
                 groups: int = 1, activation=Hardswish):
        padding = (kernel_size - 1) // 2  
        super().__init__(
            nn.Conv2d(in_channels, out_channels, kernel_size, stride, padding, groups=groups, bias=False),  
            nn.BatchNorm2d(out_channels),  
            activation(inplace=True)  
        )


class TemporalShift(nn.Module):
    """时间移位模块"""
    def __init__(self, n_div=8):
        super().__init__()
        self.n_div = n_div

    def forward(self, x, n_segment):
        return self.shift(x, n_segment, self.n_div)

    @staticmethod
    def shift(x, n_segment, n_div):
        nt, c, h, w = x.size()
        n_batch = nt // n_segment
        x = x.view(n_batch, n_segment, c, h, w)
        fold = c // n_div
        out = torch.zeros_like(x)
        out[:, :-1, :fold] = x[:, 1:, :fold]
        out[:, 1:, fold: 2 * fold] = x[:, :-1, fold: 2 * fold]
        out[:, :, 2 * fold:] = x[:, :, 2 * fold:]
        return out.view(nt, c, h, w)


class StemBlock(nn.Module):
    def __init__(self, in_channels: int, out_channels: int):
        super().__init__()
        self.conv = nn.Sequential(
            nn.Conv2d(in_channels, out_channels, kernel_size=3, stride=2, padding=1, bias=False),  
            nn.BatchNorm2d(out_channels),  
            Hardswish(inplace=True),  
        )

    def forward(self, x: Tensor) -> Tensor:
        return self.conv(x)


class OAMBConvBlock(nn.Module):
    def __init__(self, in_channels: int, out_channels: int, expand_ratio: float, stride: int,
                 kernel_size: int, use_attention: bool, drop_connect_rate: float, reduction: int,
                 num_groups: int, shift: bool = True):
        super().__init__()
        self.stride = stride  
        self.use_res_connect = stride == 1 and in_channels == out_channels  
        hidden_dim = int(in_channels * expand_ratio)  
        layers = []
        if expand_ratio != 1:
            layers.append(ConvBNActivation(in_channels, hidden_dim, kernel_size=1))  
        layers.append(ConvBNActivation(hidden_dim, hidden_dim, kernel_size=kernel_size, stride=stride,
                                       groups=hidden_dim))  
        if use_attention:
            layers.append(OptimizedAttention(hidden_dim, reduction, num_groups=num_groups))  
        layers.append(ConvBNActivation(hidden_dim, out_channels, kernel_size=1, activation=nn.Identity))  
        self.block = nn.Sequential(*layers)
        self.drop_connect_rate = drop_connect_rate if stride == 1 else 0.0  
        if shift:
            self.temporal_shift = TemporalShift()

    def forward(self, x: Tensor, n_segment: int) -> Tensor:
        if hasattr(self, 'temporal_shift'):
            x = self.temporal_shift(x, n_segment)
        out = self.block(x)
        if self.use_res_connect:
            if self.training and self.drop_connect_rate > 0:
                out = out * torch.rand([x.size(0), 1, 1, 1], device=x.device).bernoulli_(1 - self.drop_connect_rate) / (
                        1 - self.drop_connect_rate) 
            return x + out
        return out


class RefinerBlock(nn.Module):
    def __init__(self, in_channels: int, out_channels: int):
        super().__init__()
        self.avg_pool = nn.AdaptiveAvgPool2d(1)  
        self.fc = nn.Linear(in_channels, out_channels)  

    def forward(self, x: Tensor) -> Tensor:
        b, c, _, _ = x.size()
        y = self.avg_pool(x).view(b, c)  
        return self.fc(y)  


class EdgeDisNet(nn.Module):
    def __init__(self, width_coeff: float, depth_coeff: float, dropout_rate: float,
                 num_classes: int, reduction: int, drop_connect_rate: float, num_groups: int = 2):
        super().__init__()
        self.num_groups = num_groups  
        cfg = [
            (1, 24, 1, 1, 3),
            (6, 32, 2, 2, 3),
            (6, 48, 2, 2, 3),
            (6, 80, 3, 2, 3),
            (6, 112, 3, 1, 3),
            (6, 192, 4, 2, 3),
            (6, 320, 1, 1, 3),
        ]  
        in_channels = _make_divisible(16 * width_coeff, 8)  
        self.features = [StemBlock(3, in_channels)]  
        in_channels = in_channels
        use_attention_list = [False] * len(cfg)  
        use_attention_list[-2] = True  
        use_attention_list[-4] = True  

        for idx, (expand_ratio, out_channels, num_blocks, stride, kernel_size) in enumerate(cfg):
            out_channels = _make_divisible(out_channels * width_coeff, 8)  
            for i in range(round(num_blocks * depth_coeff)):
                use_attention = use_attention_list[idx]
                self.features.append(OAMBConvBlock(
                    in_channels, out_channels, expand_ratio, stride if i == 0 else 1, kernel_size,
                    use_attention, drop_connect_rate, reduction, num_groups=self.num_groups
                ))  
                in_channels = out_channels
        self.features.append(
            ConvBNActivation(in_channels, _make_divisible(256 * width_coeff, 8), kernel_size=1))  
        self.features = nn.Sequential(*self.features)
        self.refiner = RefinerBlock(_make_divisible(256 * width_coeff, 8), num_classes)  
        self.dropout = nn.Dropout(p=dropout_rate)  
        self._initialize_weights()

    def _initialize_weights(self):
        
        for m in self.modules():
            if isinstance(m, nn.Conv2d):
                nn.init.kaiming_normal_(m.weight, mode='fan_out', nonlinearity='relu')
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
            elif isinstance(m, nn.BatchNorm2d):
                nn.init.ones_(m.weight)
                nn.init.zeros_(m.bias)
            elif isinstance(m, nn.Linear):
                nn.init.normal_(m.weight, 0, 0.01)
                if m.bias is not None:
                    nn.init.zeros_(m.bias)

    def forward(self, x: Tensor) -> Tensor:
        b, t, c, h, w = x.shape
        n_segment = t
        x = x.view(b * t, c, h, w)
        for layer in self.features:
            if isinstance(layer, OAMBConvBlock):
                x = layer(x, n_segment)
            else:
                x = layer(x)
        x = self.dropout(x)  
        x = self.refiner(x)  
        x = x.view(b, t, -1).mean(1)
        return x


def edge_dis_net(num_classes: int, dropout_rate: float, reduction: int,
                 width_coeff: float, depth_coeff: float, drop_connect_rate: float,
                 num_groups: int = 2, pretrained: bool = False):
    model = EdgeDisNet(
        width_coeff=width_coeff,  
        depth_coeff=depth_coeff,  
        dropout_rate=dropout_rate,  
        num_classes=num_classes,  
        reduction=reduction,  
        drop_connect_rate=drop_connect_rate,  
        num_groups=num_groups  
    )
    return model