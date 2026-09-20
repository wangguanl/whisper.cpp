# 运行命令

- 项目：whisper.cpp
- 生成时间：2026-09-08
- 运行方式：直接运行（CMake + MSVC）
- 硬件评估：**满足**
  - 官方：支持 CPU-only；GPU（CUDA）为可选加速。large 模型约 2.9 GiB 磁盘 / ~3.9 GB 内存。
  - 本机：RTX 4080 16GB（剩余约 12.5GB）、内存 31.8GB（空闲约 10.9GB）、E: 剩余约 383GB。
  - 缺口：`nvcc` 不在 PATH，本机未装/未配置 CUDA Toolkit → **当前按 CPU 构建**（功能完整，速度慢于 CUDA）。装好 CUDA 后可用 `-DGGML_CUDA=1` 重配。

## 环境准备

```powershell
# ffmpeg（本机已有，加入会话 PATH）
$env:Path = "E:\Programs\ffmpeg-master-latest-win64-gpl\bin;$env:Path"

# 配置并编译（CPU）
cmake -B build
cmake --build build -j --config Release

# 下载 base.en（官方 huggingface.co 超时则用镜像）
$env:HF_ENDPOINT = 'https://hf-mirror.com'
# 或直接：
# Invoke-WebRequest -Uri 'https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin' -OutFile 'models\ggml-base.en.bin'
```

可选 CUDA（需先全局装好 CUDA Toolkit 且 `nvcc` 可用）：

```powershell
cmake -B build -DGGML_CUDA=1 -DCMAKE_CUDA_ARCHITECTURES="89"
cmake --build build -j --config Release
```

## 启动

- 推荐：`pwsh -NoProfile -File .\start.ps1`
- 说明：菜单可选 CLI 样例转写 或 HTTP server；默认 CLI
- 等价手动命令：
  - CLI：`.\build\bin\Release\whisper-cli.exe -m models\ggml-base.en.bin -f samples\jfk.wav`
  - Server：`.\build\bin\Release\whisper-server.exe -m models\ggml-base.en.bin --host 127.0.0.1 --port 8080`

## 验证

- CLI：对 `samples\jfk.wav` 输出含 “ask not what your country can do for you” 一类英文转写，退出码 0
- Server：`Test-NetConnection 127.0.0.1 -Port <实际端口>` 成功；或向 `/inference` 上传 wav

## 备注

- 模型源：`https://hf-mirror.com`（官方 huggingface.co 探测超时）
- 二进制路径（MSVC multi-config）：`build\bin\Release\`
- ffmpeg：`E:\Programs\ffmpeg-master-latest-win64-gpl\bin`
- 非 16-bit WAV 需先：`ffmpeg -i input.mp3 -ar 16000 -ac 1 -c:a pcm_s16le output.wav`
- 本文件与 `start.ps1` 为本机运行记录，默认不提交