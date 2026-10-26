# Build kernel muyu trên máy (WSL / Linux)

Chạy **đúng các bước** của workflow "Build muyu (Xiaomi Pad 7 Pro)" trên máy bạn, không tốn phút GitHub Actions.

`local/ghrun.py` đọc thẳng `.github/workflows/build.yml` và các action trong `.github/actions/`. Vì vậy bản build local luôn giống bản trên GitHub, kể cả sau khi bạn merge cập nhật từ WildKernels. Các bước chỉ có nghĩa trên GitHub (checkout, upload artifact, cache, dọn đĩa, swap, metadata) được bỏ qua.

| File | Dùng để |
|---|---|
| `setup-wsl.sh` | Cài gói cần thiết, tạo `/home/runner` (chạy **một lần**) |
| `build-muyu.sh` | Build kernel muyu, tạo file zip AnyKernel3 |
| `ghrun.py` | Trình chạy workflow GitHub thu nhỏ (script trên tự gọi) |

## Yêu cầu

- WSL2 Ubuntu 24.04 (hoặc Ubuntu/Debian khác)
- **Dung lượng:** khoảng 30–40 GB trống trong WSL
- **RAM:** nên cấp cho WSL **≥ 16 GB** và thêm swap, vì bước link kernel ngốn nhiều RAM. Tạo hoặc sửa file `C:\Users\<tên>\.wslconfig` trên Windows:

  ```ini
  [wsl2]
  memory=18GB
  swap=16GB
  ```

  Sau đó mở PowerShell chạy `wsl --shutdown`, rồi mở lại Ubuntu.

## Cài đặt (một lần)

Mở **Ubuntu (WSL)** rồi chạy:

```bash
git clone https://github.com/voduyai/GKI_KernelSU_SUSFS_Muyu.git ~/GKI_KernelSU_SUSFS_Muyu
cd ~/GKI_KernelSU_SUSFS_Muyu
bash local/setup-wsl.sh
```

> Phải clone **bên trong WSL** (`~/...`), đừng chạy từ `/mnt/d/...`. Bản checkout trên ổ Windows có xuống dòng CRLF làm bash lỗi, và ổ Windows cũng rất chậm khi build kernel.

## Build

```bash
cd ~/GKI_KernelSU_SUSFS_Muyu
git pull
bash local/build-muyu.sh
```

- Kết quả: `D:\Muyu\builds\local\6.1.138-android14-2025-06-KernelSU-Next-AnyKernel3-local-<ngày>.zip`
- Log: `~/muyu-build/build-<ngày giờ>.log`
- Lần đầu mất khá lâu vì phải tải source (vài GB) và build từ đầu. Các lần sau nhanh hơn nhờ cache Bazel trong `/home/runner/.cache/bazel`.

Tùy chọn:

| Lệnh | Tác dụng |
|---|---|
| `bash local/build-muyu.sh --dry-run` | Chỉ liệt kê bước nào sẽ chạy, không build |
| `bash local/build-muyu.sh --clean` | Build xong thì xóa thư mục làm việc (`~/muyu-build/workspace`), chỉ giữ file zip |
| `MUYU_OUT_DIR=~/out bash local/build-muyu.sh` | Lưu zip vào thư mục khác |

## Đổi thông số

Sửa phần `settings` ở đầu `build-muyu.sh`, giữ khớp với `.github/workflows/muyu.yml`:

- `FEATURES="SUSFS NoMount BBG NET DS NTSync Ptrace Unicode BPF"`: bỏ chữ nào thì tắt tính năng đó
- `NOMOUNT_MODE="latest"` hoặc `"verified"`
- `ALLOW_VERSION_MISMATCH=false` (bypass)

## Cập nhật từ WildKernels

Làm trên máy Windows (thư mục `D:\Muyu\GKI_KernelSU_SUSFS_Muyu`) như thường lệ: `git fetch upstream`, `git merge upstream/main`, `git push`. Sau đó trong WSL chạy `git pull` rồi build lại.

## Lỗi thường gặp

| Lỗi | Cách xử lý |
|---|---|
| `$'\r': command not found` hoặc báo "CRLF line endings" | Bạn đang chạy từ `/mnt/d/...`. Hãy dùng bản clone trong WSL |
| `/home/runner is not writable` | Chạy lại `bash local/setup-wsl.sh` |
| Build dừng đột ngột, hoặc log có `Killed` / `signal 9` | Thiếu RAM. Tăng `memory`/`swap` trong `.wslconfig` |
| `No space left on device` | Dọn `~/muyu-build` và `/home/runner/.cache/bazel` |
| NoMount metamodule | Bản local chỉ build kernel. Lấy metamodule cùng phiên bản từ https://github.com/maxsteeel/nomount/releases, hoặc từ một lượt build trên GitHub |
