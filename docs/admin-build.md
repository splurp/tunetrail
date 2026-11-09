# Building the admin version (on your own PC)

The admin version has the debug tools compiled in. It is **never** built on
GitHub or attached to releases, and its debug menu only unlocks for player ids
listed in `ADMINS` in the server's `.env`.

## One-time setup (Windows)

1. **Git**: <https://git-scm.com/download/win> (defaults are fine).
2. **Visual Studio 2022 Community**: <https://visualstudio.microsoft.com/downloads/>.
   In the installer tick **Desktop development with C++**.
3. **Flutter 3.47.9**: download the Windows zip from
   <https://docs.flutter.dev/release/archive> (Stable, 3.47.9), extract it to
   `C:\src\flutter`, then add `C:\src\flutter\bin` to your PATH
   (Start → "Edit the system environment variables" → Environment Variables →
   Path → Edit → New). Open a new PowerShell and run `flutter doctor`.
4. Get the code: `git clone https://github.com/splurp/tunetrail.git` then
   `cd tunetrail` and `git checkout ccr-3946c635-1vgat4`.

## Each time

```powershell
cd tunetrail
git pull
powershell -ExecutionPolicy Bypass -File tool\build_admin.ps1
```

The first run creates `admin-build.env` (never committed) — fill in the same
values you put in GitHub's Actions variables and secrets, and run it again.
The finished build is copied to `Desktop\Tunetrail-ADMIN`. The first build
takes several minutes; later ones are faster.
