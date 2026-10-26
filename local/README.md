# Build kernel muyu trên máy (WSL / Linux)

Chạy **đúng các bước** của workflow "Build muyu (Xiaomi Pad 7 Pro)" trên máy bạn, không tốn phút GitHub Actions.

`local/ghrun.py` đọc thẳng `.github/workflows/build.yml` và các action trong `.github/actions/`. Vì vậy bản build local luôn giống bản trên GitHub, kể cả sau khi bạn merge cập nhật từ WildKernels. Các bước chỉ có nghĩa trên GitHub (checkout, upload artifact, cache, dọn đĩa, swap, metadata) được bỏ qua.

| File | Dùng để |
|---|---|
| `setup-wsl.sh` | Cài gói cần thiết (kể cả `gh` và zig), tạo `/home/runner` (chạy **một lần**, chạy lại khi script được cập nhật) |
| `build-muyu.sh` | Build kernel muyu, tạo file zip AnyKernel3, build NoMount metamodule và tải manager APK |
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
gh auth login
```

`gh auth login` chỉ cần chạy một lần. Lệnh này cho phép script tải manager APK từ GitHub Actions: GitHub bắt buộc đăng nhập khi tải artifact. Bạn có thể bỏ qua bước này, khi đó bản build sẽ không kèm manager.

> Phải clone **bên trong WSL** (`~/...`), đừng chạy từ `/mnt/d/...`. Bản checkout trên ổ Windows có xuống dòng CRLF làm bash lỗi, và ổ Windows cũng rất chậm khi build kernel.

## Build

```bash
cd ~/GKI_KernelSU_SUSFS_Muyu
git pull
bash local/build-muyu.sh
```

- Kết quả, trong `D:\Muyu\builds\local` (hoặc thư mục `MUYU_OUT_DIR`):
  - `6.1.138-android14-2025-06-KernelSU-Next-AnyKernel3-local-<ngày>.zip`: kernel. Khi dùng `--gki`, tên file theo bản đã chọn
  - `NoMount-Metamodule-<commit>.zip`: metamodule NoMount, build từ **đúng commit** NoMount đã tích hợp vào kernel, cách làm giống job `build-nomount-module` trên CI
  - `KernelSU_Next_v…_<số>-release.apk` và bản `…-spoofed…apk`: manager, lấy y như CI từ lượt build `build-manager-ci` của KernelSU-Next chính thức (nhánh `dev`). CI cũng không tự build manager
- Nếu không build được NoMount (thiếu zig) hoặc không tải được manager (chưa `gh auth login`), kernel vẫn được đóng gói bình thường. Cuối log sẽ có dòng `WARNING: kernel built, but without: …`
- Log: `~/muyu-build/build-<ngày giờ>.log`
- Lần đầu mất khá lâu vì phải tải source (vài GB) và build từ đầu. Các lần sau nhanh hơn nhờ cache Bazel trong `/home/runner/.cache/bazel`.

Tùy chọn:

| Lệnh | Tác dụng |
|---|---|
| `bash local/build-muyu.sh --dry-run` | Chỉ liệt kê bước nào sẽ chạy, không build |
| `bash local/build-muyu.sh --clean` | Build xong thì xóa thư mục làm việc (`~/muyu-build/workspace`), chỉ giữ file zip |
| `bash local/build-muyu.sh --gki 2026-09` | Build bản GKI `android14-6.1` khác (ở đây là 6.1.176). Mặc định là `2025-06` = kernel stock muyu (tag `_r15`). Ghi sai ngày thì script sẽ liệt kê các bản có sẵn |
| `bash local/build-muyu.sh --kernel-only` | Chỉ build kernel, không build NoMount và không tải manager |
| `MUYU_OUT_DIR=~/out bash local/build-muyu.sh` | Lưu zip và APK vào thư mục khác |

## Đổi thông số

Sửa phần `settings` ở đầu `build-muyu.sh`, giữ khớp với `.github/workflows/muyu.yml`:

- `FEATURES="SUSFS NoMount BBG NET DS NTSync Ptrace Unicode BPF"`: bỏ chữ nào thì tắt tính năng đó
- `NOMOUNT_MODE="latest"` hoặc `"verified"`
- `ALLOW_VERSION_MISMATCH=false` (bypass)

### Bản GKI mới hơn stock (`--gki`)

Chỉ nên chọn bản trong nhánh `android14-6.1`. Module vendor của muyu được build cho KMI này. Nhảy sang `android15-6.6` trở lên chắc chắn bootloop.

Riêng bản `2025-06` được chỉnh cho giống hệt kernel stock: ghim tag `_r15`, chuỗi phiên bản và giờ build giống bản gốc. Các bản khác giữ nguyên chuỗi phiên bản của Google.

Lên bản mới hơn, một vài module trong `system_dlkm` (build cùng kernel stock 6.1.138) có thể không load được. Khi thử, hãy flash vào slot không dùng, rồi kiểm tra Wi-Fi, Bluetooth, zram và lệnh:

```bash
adb shell su -c 'dmesg | grep -iE "disagrees|unknown symbol"'
```

## Cập nhật từ WildKernels

Làm trên máy Windows (thư mục `D:\Muyu\GKI_KernelSU_SUSFS_Muyu`) như thường lệ: `git fetch upstream`, `git merge upstream/main`, `git push`. Sau đó trong WSL chạy `git pull` rồi build lại.

## Lỗi thường gặp

| Lỗi | Cách xử lý |
|---|---|
| `$'\r': command not found` hoặc báo "CRLF line endings" | Bạn đang chạy từ `/mnt/d/...`. Hãy dùng bản clone trong WSL |
| `/home/runner is not writable` | Chạy lại `bash local/setup-wsl.sh` |
| Build dừng đột ngột, hoặc log có `Killed` / `signal 9` | Thiếu RAM. Tăng `memory`/`swap` trong `.wslconfig` |
| `No space left on device` | Dọn `~/muyu-build` và `/home/runner/.cache/bazel` |
| `zig not found` | Chạy lại `bash local/setup-wsl.sh` (bản mới có cài zig) |
| `not logged in to GitHub` | Chạy `gh auth login` một lần, rồi build lại. Muốn bỏ qua manager thì thêm `--kernel-only` |
| `run … has no manager APKs (artifacts expired?)` | Artifact của lượt build manager đã hết hạn. Đợi KernelSU-Next có lượt build `dev` mới, hoặc tải manager ở trang Releases của KernelSU-Next |
