#!/usr/bin/env python3
"""
导出 Essentia 节拍表为 CSV
用法:
    python essentia_to_CSV.py <音频文件路径>
示例:
    python essentia_to_CSV.py "song.wav"
输出:
    同目录下生成 <音频文件名>_beats.csv
"""

import sys
import os
import argparse

try:
    import essentia.standard as es
except ImportError:
    print("错误：未安装 Essentia。请运行: pip install essentia-tensorflow", file=sys.stderr)
    sys.exit(1)


def detect_beats(audio_path, min_bpm=55, max_bpm=215):
    """
    使用 Essentia 检测节拍时间戳
    返回: 节拍时间列表 (秒)
    """
    # 加载音频（单声道，采样率 44100 Hz）
    loader = es.MonoLoader(filename=audio_path, sampleRate=44100)
    audio = loader()

    # 使用 RhythmExtractor2013
    # method='multifeature' 提供更精确的节拍检测（同时也输出置信度）
    # 如果你想更快，可以用 'degara'，但 degara 不输出 confidence
    rhythm = es.RhythmExtractor2013(method="multifeature")
    bpm, beats, confidence, estimates, bpm_intervals = rhythm(audio)

    # beats 是一个 numpy 数组，转换为列表
    return beats.tolist()


def save_beats_to_csv(beats, csv_path, song_name, model_name="essentia"):
    """
    将节拍列表保存为 CSV 文件
    格式:
        # song=<歌曲标识>
        # model=<模型名称>
        <时间戳1>
        <时间戳2>
        ...
    注意：时间戳以原始精度存储，不进行格式化截断。
    """
    with open(csv_path, 'w', encoding='utf-8') as f:
        f.write(f"# song={song_name}\n")
        f.write(f"# model={model_name}\n")
        for beat in beats:
            f.write(f"{beat}\n")   # 直接使用 str(beat)，保留原始精度


def main():
    parser = argparse.ArgumentParser(
        description="导出 Essentia 节拍表为 CSV"
    )
    parser.add_argument(
        "audio_file",
        help="音频文件路径 (支持 WAV, MP3, FLAC, OGG, M4A 等 Essentia 可读格式)"
    )
    parser.add_argument(
        "-o", "--output",
        help="输出 CSV 文件路径 (默认: 与音频同目录，文件名替换扩展名为 _beats.csv)"
    )
    args = parser.parse_args()

    audio_path = args.audio_file
    if not os.path.isfile(audio_path):
        print(f"错误：文件不存在 - {audio_path}", file=sys.stderr)
        sys.exit(1)

    if args.output:
        csv_path = args.output
    else:
        base = os.path.splitext(audio_path)[0]
        csv_path = base + "_beats.csv"

    song_name = os.path.splitext(os.path.basename(audio_path))[0]

    print(f"正在分析音频: {audio_path}")
    try:
        beats = detect_beats(audio_path)
    except Exception as e:
        print(f"节拍检测失败: {e}", file=sys.stderr)
        sys.exit(1)

    if not beats:
        print("警告：未检测到任何节拍，将生成空文件", file=sys.stderr)

    save_beats_to_csv(beats, csv_path, song_name, model_name="essentia")
    print(f"节拍表已保存至: {csv_path}")
    print(f"共 {len(beats)} 个节拍")


if __name__ == "__main__":
    main()