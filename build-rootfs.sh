SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOTFS_ARCHIVES_DIR="$SCRIPT_DIR/rootfs/archives"
FETCH_ASSETS_SCRIPT="$SCRIPT_DIR/scripts/fetch-large-assets.sh"

ensure_rootfs_archives() {
  if [[ -f "$ROOTFS_ARCHIVES_DIR/data.tar.xz" ]]; then
    return 0
  fi
  if [[ -x "$FETCH_ASSETS_SCRIPT" ]]; then
    echo "[build-rootfs] data.tar.xz not found. Fetching large assets..."
    "$FETCH_ASSETS_SCRIPT"
  fi
  if [[ ! -f "$ROOTFS_ARCHIVES_DIR/data.tar.xz" ]]; then
    echo "[build-rootfs] Missing $ROOTFS_ARCHIVES_DIR/data.tar.xz" >&2
    exit 1
  fi
}

patchelf_fix() {
  LD_RPATH=/data/data/com.winlator/files/rootfs/lib
  LD_FILE=$LD_RPATH/ld-linux-aarch64.so.1
  
  # 特别处理 GStreamer 插件目录
  if [ -d "/data/data/com.winlator/files/rootfs/lib/gstreamer-1.0" ]; then
    find "/data/data/com.winlator/files/rootfs/lib/gstreamer-1.0" -name "*.so" -type f | while read -r plugin; do
      echo "Patching GStreamer plugin: $plugin"
      patchelf --set-rpath "$LD_RPATH" --set-interpreter "$LD_FILE" "$plugin" || echo "Warning: Failed to patch $plugin"
    done
  fi
  
  # 原有的 ELF 文件修补
  find . -type f -exec file {} + | grep -E ":.*ELF" | cut -d: -f1 | while read -r elf_file; do
    echo "Patching $elf_file..."
    patchelf --set-rpath "$LD_RPATH" --set-interpreter "$LD_FILE" "$elf_file" || {
      echo "Failed to patch $elf_file" >&2
      continue
    }
  done
}
create_ver_txt () {
  cat > '/data/data/com.winlator/files/rootfs/_version_.txt' << EOF
Output Date(UTC+8): $date
Version:
  gstreamer=> $gstVer
  xz=> $xzVer
  rootfs-tag=> $customTag
Repo:
  [FrontMage/winlator-llm](https://github.com/FrontMage/winlator-llm)
EOF
}
if [[ ! -f /tmp/init.sh ]]; then
  exit 1
else
  source /tmp/init.sh
  echo "gst=> $gstVer"
  # echo "vorbis=> $vorbisVer"
  echo "xz=> $xzVer"
fi
pacman -R --noconfirm libvorbis flac lame
pacman -Sy --noconfirm
pacman -S --noconfirm --needed samba

# Install ntlm_auth and required Samba libraries into rootfs
ROOTFS_DIR=/data/data/com.winlator/files/rootfs
mkdir -p "$ROOTFS_DIR"
NTLM_AUTH_BIN="/usr/bin/ntlm_auth"
if [[ ! -x "$NTLM_AUTH_BIN" ]]; then
  echo "[build-rootfs] ERROR: ntlm_auth not found after installing samba" >&2
  exit 1
fi
mkdir -p "$ROOTFS_DIR/usr/bin"
cp -a "$NTLM_AUTH_BIN" "$ROOTFS_DIR/usr/bin/ntlm_auth"

# Copy Samba-related shared libraries from packages that provide ntlm_auth and samba libs
copy_pkg_shared_libs() {
  local pkg="$1"
  if [[ -z "$pkg" ]]; then
    return
  fi
  pacman -Ql "$pkg" 2>/dev/null | awk '{print $2}' | while read -r path; do
    [[ -f "$path" ]] || continue
    case "$path" in
      *.so|*.so.*)
        local dest="$ROOTFS_DIR$path"
        mkdir -p "$(dirname "$dest")"
        cp -a "$path" "$dest"
        ;;
    esac
  done
}

pkg_list=$(pacman -Qqo /usr/bin/ntlm_auth /usr/lib/samba 2>/dev/null | sort -u)
for pkg in $pkg_list; do
  copy_pkg_shared_libs "$pkg"
done

# Copy Samba plugin directories (used by ntlm_auth)
for libdir in /usr/lib/samba /usr/lib/samba/private; do
  if [[ -d "$libdir" ]]; then
    mkdir -p "$ROOTFS_DIR$libdir"
    cp -a "$libdir"/. "$ROOTFS_DIR$libdir/"
  fi
done

# Ensure libwbclient and its deps are included (ntlm_auth depends on it)
for wb in /usr/lib/libwbclient.so*; do
  if [[ -f "$wb" ]]; then
    dest="$ROOTFS_DIR$wb"
    mkdir -p "$(dirname "$dest")"
    cp -a "$wb" "$dest"
  fi
done

mkdir -p /data/data/com.winlator/files/rootfs/
ROOTFS_BASE_REPO="${ROOTFS_BASE_REPO:-FrontMage/winlator-llm}"
ROOTFS_BASE_TAG="${ROOTFS_BASE_TAG:-rootfs-base-10.1}"
ROOTFS_BASE_FILE="${ROOTFS_BASE_FILE:-rootfs-10.1.tzst}"
ROOTFS_BASE_URL="https://github.com/${ROOTFS_BASE_REPO}/releases/download/${ROOTFS_BASE_TAG}/${ROOTFS_BASE_FILE}"
ROOTFS_BASE_PATH="/tmp/rootfs.tzst"

cd /tmp
if ! wget -O "$ROOTFS_BASE_PATH" "$ROOTFS_BASE_URL"; then
  echo "[build-rootfs] Failed to download base rootfs: $ROOTFS_BASE_URL" >&2
  exit 1
fi
#tar -xf rootfs.tzst -C /data/data/com.winlator/files/rootfs/
#tar -xf data.tar.xz -C /data/data/com.winlator/files/rootfs/
#tar -xf tzdata-*-.pkg.tar.xz -C /data/data/com.winlator/files/rootfs/
cd /data/data/com.winlator/files/rootfs/etc
mkdir ca-certificates
if ! wget https://curl.haxx.se/ca/cacert.pem; then
  exit 1
fi
cd /tmp
rm -rf /data/data/com.winlator/files/rootfs/lib/libgst*
rm -rf /data/data/com.winlator/files/rootfs/lib/gstreamer-1.0
#git clone https://github.com/xiph/flac.git flac-src
if ! git clone -b $xzVer https://github.com/tukaani-project/xz.git xz-src; then
  exit 1
fi
# if ! git clone  -b $vorbisVer https://github.com/xiph/vorbis.git vorbis-src; then
#   exit 1
# fi
#git clone https://github.com/xiph/opus.git opus-src
if ! git clone -b $gstVer https://github.com/GStreamer/gstreamer.git gst-src; then
  exit 1
fi

# Build
echo "Build and Compile xz(liblzma)"
cd /tmp/xz-src
./autogen.sh
mkdir build
cd build
if ! ../configure -prefix=/data/data/com.winlator/files/rootfs/; then
  exit 1
fi
if ! make -j$(nproc); then
  exit 1
fi
make install
# cd /tmp/vorbis-src
# echo "Build and Compile vorbis"
# if ! ./autogen.sh; then
#   exit 1
# fi
# if ! ./configure --prefix=/data/data/com.winlator/files/rootfs/; then
#   exit 1
# fi
# if ! make -j$(nproc); then
#   exit 1
# fi
# make install
cd /tmp/gst-src
echo "Build and Compile gstreamer"
meson setup builddir \
  --buildtype=release \
  --strip \
  -Dgst-full-target-type=shared_library \
  -Dintrospection=disabled \
  -Dgst-full-libraries=app,video,player \
  -Dbase=enabled \
  -Dgood=enabled \
  -Dbad=enabled \
  -Dugly=enabled \
  -Dlibav=enabled \
  -Dtests=disabled \
  -Dexamples=disabled \
  -Ddoc=disabled \
  -Dges=disabled \
  -Dpython=disabled \
  -Ddevtools=disabled \
  -Dgstreamer:check=disabled \
  -Dgstreamer:benchmarks=disabled \
  -Dgstreamer:libunwind=disabled \
  -Dgstreamer:libdw=disabled \
  -Dgstreamer:bash-completion=disabled \
  -Dgst-plugins-good:cairo=disabled \
  -Dgst-plugins-good:gdk-pixbuf=disabled \
  -Dgst-plugins-good:oss=disabled \
  -Dgst-plugins-good:oss4=disabled \
  -Dgst-plugins-good:v4l2=disabled \
  -Dgst-plugins-good:aalib=disabled \
  -Dgst-plugins-good:jack=disabled \
  -Dgst-plugins-good:pulse=enabled \
  -Dgst-plugins-good:adaptivedemux2=disabled \
  -Dgst-plugins-good:v4l2=disabled \
  -Dgst-plugins-good:libcaca=disabled \
  -Dgst-plugins-good:mpg123=enabled \
  -Dgst-plugins-base:examples=disabled \
  -Dgst-plugins-base:alsa=enabled \
  -Dgst-plugins-base:pango=disabled \
  -Dgst-plugins-base:x11=enabled \
  -Dgst-plugins-base:gl=disabled \
  -Dgst-plugins-base:opus=disabled \
  -Dgst-plugins-bad:androidmedia=disabled \
  -Dgst-plugins-bad:rtmp=disabled \
  -Dgst-plugins-bad:shm=disabled \
  -Dgst-plugins-bad:zbar=disabled \
  -Dgst-plugins-bad:webp=disabled \
  -Dgst-plugins-bad:kms=disabled \
  -Dgst-plugins-bad:vulkan=disabled \
  -Dgst-plugins-bad:dash=disabled \
  -Dgst-plugins-bad:analyticsoverlay=disabled \
  -Dgst-plugins-bad:nvcodec=disabled \
  -Dgst-plugins-bad:uvch264=disabled \
  -Dgst-plugins-bad:v4l2codecs=disabled \
  -Dgst-plugins-bad:udev=disabled \
  -Dgst-plugins-bad:libde265=disabled \
  -Dgst-plugins-bad:smoothstreaming=disabled \
  -Dgst-plugins-bad:fluidsynth=disabled \
  -Dgst-plugins-bad:inter=disabled \
  -Dgst-plugins-bad:x11=enabled \
  -Dgst-plugins-bad:gl=disabled \
  -Dgst-plugins-bad:wayland=disabled \
  -Dgst-plugins-bad:openh264=disabled \
  -Dgst-plugins-bad:hip=disabled \
  -Dgst-plugins-bad:aja=disabled \
  -Dgst-plugins-bad:aes=disabled \
  -Dgst-plugins-bad:dtls=disabled \
  -Dgst-plugins-bad:hls=disabled \
  -Dgst-plugins-bad:curl=disabled \
  -Dgst-plugins-bad:opus=disabled \
  -Dgst-plugins-bad:webrtc=disabled \
  -Dgst-plugins-bad:webrtcdsp=disabled \
  -Dpackage-origin="[gstremaer-build] (https://github.com/Waim908/gstreamer-build)" \
  --prefix=/data/data/com.winlator/files/rootfs/ || exit 1
if [[ ! -d builddir ]]; then
  exit 1
fi
if ! meson compile -C builddir; then
  exit 1
fi
meson install -C builddir
export date=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
# package
echo "Package"
mkdir /tmp/output
cd /data/data/com.winlator/files/rootfs/
patchelf_fix
create_ver_txt
if ! tar -I 'xz -T8' -cf /tmp/output/output-lite.tar.xz *; then
  exit 1
fi
cd /tmp
ensure_rootfs_archives
tar -xf "$ROOTFS_ARCHIVES_DIR/data.tar.xz" -C /data/data/com.winlator/files/rootfs/
tar -xf "$ROOTFS_ARCHIVES_DIR/tzdata-2025b-1-aarch64.pkg.tar.xz" -C /data/data/com.winlator/files/rootfs/
cd /data/data/com.winlator/files/rootfs/
create_ver_txt
if ! tar -I 'xz -T8' -cf /tmp/output/output-full.tar.xz *; then
  exit 1
fi
rm -rf /data/data/com.winlator/files/rootfs/*
if ! tar -xf /tmp/rootfs.tzst -C /data/data/com.winlator/files/rootfs/; then
  echo "Failed to extract /tmp/rootfs.tzst" >&2
  exit 1
fi
if ! tar -xf /tmp/output/output-full.tar.xz -C /data/data/com.winlator/files/rootfs/; then
  echo "Failed to extract /tmp/output/output-full.tar.xz" >&2
  exit 1
fi
cd /data/data/com.winlator/files/rootfs/
create_ver_txt
if ! tar -I 'zstd -T8' -cf /tmp/output/rootfs.tzst *; then
  exit 1
fi
