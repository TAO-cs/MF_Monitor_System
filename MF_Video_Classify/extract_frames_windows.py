import cv2
import os
from pathlib import Path
from tqdm import tqdm

def video_to_frames(input_dir, output_root):
    # 定义支持的视频格式
    valid_extensions = {'.avi', '.mp4', '.mov', '.mkv', '.flv'}
    
    # 使用 Path 对象处理路径，兼容 Windows
    input_path = Path(input_dir)
    output_path = Path(output_root)
    
    if not input_path.exists():
        print(f"❌ 错误：找不到输入文件夹: {input_dir}")
        print("请检查路径是否正确，注意区分大小写和空格。")
        return

    # 获取所有视频文件
    video_files = [p for p in input_path.iterdir() if p.suffix.lower() in valid_extensions]
    
    if not video_files:
        print(f"⚠️ 在文件夹中没有找到视频文件: {input_dir}")
        return

    print(f"📂 发现 {len(video_files)} 个视频，准备提取帧...")
    print(f"📂 输出目录: {output_root}")

    for video_file in tqdm(video_files, desc="处理进度"):
        # 1. 创建对应的输出文件夹
        # 例如: wrong/test.avi -> wrong_frames/test/
        folder_name = video_file.stem
        save_dir = output_path / folder_name
        save_dir.mkdir(parents=True, exist_ok=True)
        
        # 2. 读取视频
        cap = cv2.VideoCapture(str(video_file))
        if not cap.isOpened():
            print(f"❌ 无法打开视频: {video_file.name}")
            continue
            
        frame_idx = 0
        
        while True:
            ret, frame = cap.read()
            if not ret:
                break
            
            # 3. 保存图片
            # 命名格式: 000001.jpg
            frame_name = f"{frame_idx:06d}.jpg"
            save_path = save_dir / frame_name
            
            # 质量设为 95
            cv2.imwrite(str(save_path), frame, [cv2.IMWRITE_JPEG_QUALITY, 95])
            
            frame_idx += 1
            
        cap.release()
        
    print(f"\n✅ 处理完成！请查看文件夹: {output_root}")

if __name__ == "__main__":
    # === 配置路径 ===
    # 注意：Windows 路径前加 r，防止转义错误
    INPUT_FOLDER = r"C:\Users\chens\Desktop\wrong"
    OUTPUT_FOLDER = r"C:\Users\chens\Desktop\wrong_frames"
    
    video_to_frames(INPUT_FOLDER, OUTPUT_FOLDER)