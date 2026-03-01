#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GNUTLS_VERSION="${GNUTLS_VERSION:-3.8.9}"
NETTLE_VERSION="${NETTLE_VERSION:-3.10.1}"
GMP_VERSION="${GMP_VERSION:-6.3.0}"
ANDROID_API="${ANDROID_API:-26}"
NDK_ROOT="${NDK_ROOT:-$HOME/Library/Android/sdk/ndk/26.1.10909125}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/out/_build_gnutls_android}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/gnutls-android}"
FORCE_CLEAN=0
HTTP_PROXY_OPT=""
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"

usage() {
  cat <<'USAGE'
Build Android ARM64 (bionic) GnuTLS shared libraries with self-contained deps.

Usage:
  scripts/build-gnutls-android.sh [options]

Options:
  --ndk <path>          Android NDK root (default: ~/Library/Android/sdk/ndk/26.1.10909125)
  --api <level>         Android API level (default: 26)
  --version <ver>       GnuTLS version (default: 3.8.9)
  --nettle-version <v>  Nettle version to build (default: 3.10.1)
  --gmp-version <v>     GMP version to build (default: 6.3.0)
  --work-dir <path>     Build workspace (default: out/_build_gnutls_android)
  --out-dir <path>      Output directory (default: out/gnutls-android)
  --http-proxy <url>    HTTP/HTTPS proxy for downloads (e.g. http://192.168.0.102:8080)
  --clean               Remove existing workspace before build
  -h, --help            Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ndk) NDK_ROOT="$2"; shift 2 ;;
    --api) ANDROID_API="$2"; shift 2 ;;
    --version) GNUTLS_VERSION="$2"; shift 2 ;;
    --nettle-version) NETTLE_VERSION="$2"; shift 2 ;;
    --gmp-version) GMP_VERSION="$2"; shift 2 ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --http-proxy) HTTP_PROXY_OPT="$2"; shift 2 ;;
    --clean) FORCE_CLEAN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$HTTP_PROXY_OPT" ]]; then
  export http_proxy="$HTTP_PROXY_OPT"
  export https_proxy="$HTTP_PROXY_OPT"
fi

if [[ ! -d "$NDK_ROOT" ]]; then
  echo "[gnutls-android] NDK not found: $NDK_ROOT" >&2
  exit 1
fi

PREBUILT=""
if [[ -d "$NDK_ROOT/toolchains/llvm/prebuilt/darwin-arm64" ]]; then
  PREBUILT="$NDK_ROOT/toolchains/llvm/prebuilt/darwin-arm64"
elif [[ -d "$NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64" ]]; then
  PREBUILT="$NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64"
else
  echo "[gnutls-android] No darwin prebuilt toolchain in $NDK_ROOT/toolchains/llvm/prebuilt" >&2
  exit 1
fi

if [[ "$FORCE_CLEAN" -eq 1 ]]; then
  rm -rf "$WORK_DIR"
fi
mkdir -p "$WORK_DIR" "$OUT_DIR"

TOOLCHAIN_BIN="$PREBUILT/bin"
HOST_TRIPLE="aarch64-linux-android"
CC="$TOOLCHAIN_BIN/${HOST_TRIPLE}${ANDROID_API}-clang"
CXX="$TOOLCHAIN_BIN/${HOST_TRIPLE}${ANDROID_API}-clang++"
AR="$TOOLCHAIN_BIN/llvm-ar"
RANLIB="$TOOLCHAIN_BIN/llvm-ranlib"
STRIP="$TOOLCHAIN_BIN/llvm-strip"
READELF="$TOOLCHAIN_BIN/llvm-readelf"
NM="$TOOLCHAIN_BIN/llvm-nm"

for tool in "$CC" "$CXX" "$AR" "$RANLIB" "$STRIP" "$READELF" "$NM"; do
  if [[ ! -x "$tool" ]]; then
    echo "[gnutls-android] Missing tool: $tool" >&2
    exit 1
  fi
done

GNUTLS_TARBALL="gnutls-${GNUTLS_VERSION}.tar.xz"
GNUTLS_DIR="$WORK_DIR/gnutls-${GNUTLS_VERSION}"
GNUTLS_TARBALL_PATH="$WORK_DIR/$GNUTLS_TARBALL"
NETTLE_TARBALL="nettle-${NETTLE_VERSION}.tar.gz"
NETTLE_DIR="$WORK_DIR/nettle-${NETTLE_VERSION}"
NETTLE_TARBALL_PATH="$WORK_DIR/$NETTLE_TARBALL"
GMP_TARBALL="gmp-${GMP_VERSION}.tar.xz"
GMP_DIR="$WORK_DIR/gmp-${GMP_VERSION}"
GMP_TARBALL_PATH="$WORK_DIR/$GMP_TARBALL"
CRYPTO_PREFIX="$WORK_DIR/sysroot-crypto"

download() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    echo "[gnutls-android] neither curl nor wget is available" >&2
    exit 1
  fi
}

if [[ ! -f "$GNUTLS_TARBALL_PATH" ]]; then
  echo "[gnutls-android] Downloading $GNUTLS_TARBALL ..."
  if ! download "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/${GNUTLS_TARBALL}" "$GNUTLS_TARBALL_PATH"; then
    echo "[gnutls-android] Primary URL failed, trying kernel mirror ..."
    download "https://mirrors.kernel.org/gnu/gnutls/${GNUTLS_TARBALL}" "$GNUTLS_TARBALL_PATH"
  fi
fi

if [[ ! -f "$NETTLE_TARBALL_PATH" ]]; then
  echo "[gnutls-android] Downloading $NETTLE_TARBALL ..."
  if ! download "https://ftp.gnu.org/gnu/nettle/${NETTLE_TARBALL}" "$NETTLE_TARBALL_PATH"; then
    echo "[gnutls-android] Primary URL failed, trying kernel mirror ..."
    download "https://mirrors.kernel.org/gnu/nettle/${NETTLE_TARBALL}" "$NETTLE_TARBALL_PATH"
  fi
fi

if [[ ! -f "$GMP_TARBALL_PATH" ]]; then
  echo "[gnutls-android] Downloading $GMP_TARBALL ..."
  if ! download "https://ftp.gnu.org/gnu/gmp/${GMP_TARBALL}" "$GMP_TARBALL_PATH"; then
    echo "[gnutls-android] Primary URL failed, trying kernel mirror ..."
    download "https://mirrors.kernel.org/gnu/gmp/${GMP_TARBALL}" "$GMP_TARBALL_PATH"
  fi
fi

if [[ ! -d "$GNUTLS_DIR" ]]; then
  echo "[gnutls-android] Extracting $GNUTLS_TARBALL ..."
  tar -xf "$GNUTLS_TARBALL_PATH" -C "$WORK_DIR"
fi

if [[ ! -d "$NETTLE_DIR" ]]; then
  echo "[gnutls-android] Extracting $NETTLE_TARBALL ..."
  tar -xf "$NETTLE_TARBALL_PATH" -C "$WORK_DIR"
fi

if [[ ! -d "$GMP_DIR" ]]; then
  echo "[gnutls-android] Extracting $GMP_TARBALL ..."
  tar -xf "$GMP_TARBALL_PATH" -C "$WORK_DIR"
fi

echo "[gnutls-android] Building gmp for Android ..."
rm -rf "$CRYPTO_PREFIX"
mkdir -p "$CRYPTO_PREFIX"
cd "$GMP_DIR"
rm -rf build-android
mkdir -p build-android
cd build-android

export CC CXX AR RANLIB STRIP
GMP_CFLAGS="-fPIC -O2 -DANDROID -D__ANDROID_API__=${ANDROID_API}"
GMP_LDFLAGS="-Wl,--no-undefined"

../configure \
  --host="$HOST_TRIPLE" \
  --prefix="$CRYPTO_PREFIX" \
  --enable-shared \
  --disable-static \
  CFLAGS="$GMP_CFLAGS" \
  LDFLAGS="$GMP_LDFLAGS"

make -j"$JOBS"
make install

if [[ ! -f "$CRYPTO_PREFIX/lib/libgmp.so" && ! -f "$CRYPTO_PREFIX/lib/libgmp.so.10" ]]; then
  echo "[gnutls-android] gmp build failed" >&2
  exit 1
fi

echo "[gnutls-android] Building nettle/hogweed for Android ..."
cd "$NETTLE_DIR"
rm -rf build-android
mkdir -p build-android
cd build-android

export CC CXX AR RANLIB STRIP
export ac_cv_func_malloc_0_nonnull=yes
export ac_cv_func_realloc_0_nonnull=yes
NETTLE_CFLAGS="-fPIC -O2 -DANDROID -D__ANDROID_API__=${ANDROID_API}"
NETTLE_CPPFLAGS="-I$CRYPTO_PREFIX/include"
NETTLE_LDFLAGS="-Wl,--no-undefined -L$CRYPTO_PREFIX/lib"
export PKG_CONFIG="${PKG_CONFIG:-$(command -v pkg-config || true)}"
if [[ -z "$PKG_CONFIG" ]]; then
  echo "[gnutls-android] pkg-config is required but not found in PATH" >&2
  exit 1
fi
export PKG_CONFIG_LIBDIR="$CRYPTO_PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$CRYPTO_PREFIX/lib/pkgconfig"

../configure \
  --host="$HOST_TRIPLE" \
  --prefix="$CRYPTO_PREFIX" \
  --disable-mini-gmp \
  --enable-shared \
  --disable-static \
  CPPFLAGS="$NETTLE_CPPFLAGS" \
  CFLAGS="$NETTLE_CFLAGS" \
  LDFLAGS="$NETTLE_LDFLAGS"

make -j"$JOBS"
make install

if [[ ! -f "$CRYPTO_PREFIX/lib/libnettle.so" || ! -f "$CRYPTO_PREFIX/lib/libhogweed.so" ]]; then
  echo "[gnutls-android] nettle/hogweed build failed" >&2
  exit 1
fi

echo "[gnutls-android] Verifying nettle symbols ..."
"$NM" -D "$CRYPTO_PREFIX/lib/libhogweed.so" | rg -n "nettle_rsa_sec_decrypt" -S || {
  echo "[gnutls-android] libhogweed.so missing nettle_rsa_sec_decrypt" >&2
  exit 1
}

cd "$GNUTLS_DIR"

# Battle.net on this stack looks up legacy/non-public ECDH symbols.
# When ENABLE_FIPS140 is off, upstream may not export _gnutls_ecdh_compute_key.
# Inject a compatibility implementation + alias symbol to satisfy runtime linking.
GNUTLS_PK_C="$GNUTLS_DIR/lib/nettle/pk.c"
if ! rg -q "WINLATOR_COMPAT_ECDH_EXPORTS" "$GNUTLS_PK_C"; then
  cat >>"$GNUTLS_PK_C" <<'EOF'

/* WINLATOR_COMPAT_ECDH_EXPORTS: Battle.net compatibility exports. */
#ifndef ENABLE_FIPS140
int _gnutls_ecdh_compute_key(gnutls_ecc_curve_t curve, const gnutls_datum_t *x,
			     const gnutls_datum_t *y, const gnutls_datum_t *k,
			     const gnutls_datum_t *peer_x,
			     const gnutls_datum_t *peer_y, gnutls_datum_t *Z)
{
	gnutls_pk_params_st pub, priv;
	int ret;

	gnutls_pk_params_init(&pub);
	pub.params_nr = 3;
	pub.algo = GNUTLS_PK_ECDSA;
	pub.curve = curve;

	gnutls_pk_params_init(&priv);
	priv.params_nr = 3;
	priv.algo = GNUTLS_PK_ECDSA;
	priv.curve = curve;

	if (_gnutls_mpi_init_scan_nz(&pub.params[ECC_Y], peer_y->data, peer_y->size) != 0) {
		ret = gnutls_assert_val(GNUTLS_E_MPI_SCAN_FAILED);
		goto cleanup;
	}
	if (_gnutls_mpi_init_scan_nz(&pub.params[ECC_X], peer_x->data, peer_x->size) != 0) {
		ret = gnutls_assert_val(GNUTLS_E_MPI_SCAN_FAILED);
		goto cleanup;
	}
	if (_gnutls_mpi_init_scan_nz(&priv.params[ECC_Y], y->data, y->size) != 0) {
		ret = gnutls_assert_val(GNUTLS_E_MPI_SCAN_FAILED);
		goto cleanup;
	}
	if (_gnutls_mpi_init_scan_nz(&priv.params[ECC_X], x->data, x->size) != 0) {
		ret = gnutls_assert_val(GNUTLS_E_MPI_SCAN_FAILED);
		goto cleanup;
	}
	if (_gnutls_mpi_init_scan_nz(&priv.params[ECC_K], k->data, k->size) != 0) {
		ret = gnutls_assert_val(GNUTLS_E_MPI_SCAN_FAILED);
		goto cleanup;
	}

	Z->data = NULL;
	ret = _gnutls_pk_derive(GNUTLS_PK_ECDSA, Z, &priv, &pub);
	if (ret < 0) {
		gnutls_assert();
		goto cleanup;
	}

	ret = 0;
cleanup:
	gnutls_pk_params_clear(&pub);
	gnutls_pk_params_release(&pub);
	gnutls_pk_params_clear(&priv);
	gnutls_pk_params_release(&priv);
	return ret;
}
#endif

int gnutls_ecdh_compute_key(gnutls_ecc_curve_t curve, const gnutls_datum_t *x,
			    const gnutls_datum_t *y, const gnutls_datum_t *k,
			    const gnutls_datum_t *peer_x,
			    const gnutls_datum_t *peer_y, gnutls_datum_t *Z)
{
	return _gnutls_ecdh_compute_key(curve, x, y, k, peer_x, peer_y, Z);
}
EOF
fi

# Keep build deterministic across rebuilds.
rm -rf build-android
mkdir -p build-android
cd build-android

export CC CXX AR RANLIB STRIP
# GnuTLS configure requires pkg-config to exist even when using bundled deps.
export PKG_CONFIG="${PKG_CONFIG:-$(command -v pkg-config || true)}"
if [[ -z "$PKG_CONFIG" ]]; then
  echo "[gnutls-android] pkg-config is required but not found in PATH" >&2
  exit 1
fi
export PKG_CONFIG_LIBDIR="$CRYPTO_PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$CRYPTO_PREFIX/lib/pkgconfig"
export ac_cv_func_malloc_0_nonnull=yes
export ac_cv_func_realloc_0_nonnull=yes

CFLAGS_COMMON="-fPIC -O2 -DANDROID -D__ANDROID_API__=${ANDROID_API}"
CPPFLAGS_COMMON="-I$CRYPTO_PREFIX/include"
LDFLAGS_COMMON="-Wl,--no-undefined -L$CRYPTO_PREFIX/lib"

echo "[gnutls-android] Configuring ..."
../configure \
  --host="$HOST_TRIPLE" \
  --prefix=/usr \
  --enable-shared \
  --disable-static \
  --disable-doc \
  --disable-tools \
  --disable-tests \
  --without-idn \
  --without-p11-kit \
  --without-zlib \
  --without-brotli \
  --with-included-libtasn1 \
  --with-included-unistring \
  --with-nettle-mini=no \
  CPPFLAGS="$CPPFLAGS_COMMON" \
  CFLAGS="$CFLAGS_COMMON" \
  CXXFLAGS="$CFLAGS_COMMON" \
  LDFLAGS="$LDFLAGS_COMMON"

echo "[gnutls-android] Building ..."
make -j"$JOBS"

LIB_OUT="$(find . -type f \( -name 'libgnutls.so' -o -name 'libgnutls.so.*' \) | head -n1)"
if [[ -z "$LIB_OUT" ]]; then
  echo "[gnutls-android] libgnutls.so not found in build output" >&2
  exit 1
fi

cp -f "$LIB_OUT" "$OUT_DIR/libgnutls.so"
if [[ -f ./libdane/.libs/libgnutls-dane.so ]]; then
  cp -f ./libdane/.libs/libgnutls-dane.so "$OUT_DIR/libgnutls-dane.so"
fi
if [[ -f ./lib/.libs/libgnutlsxx.so ]]; then
  cp -f ./lib/.libs/libgnutlsxx.so "$OUT_DIR/libgnutlsxx.so"
fi
for dep in libgmp.so* libnettle.so* libhogweed.so*; do
  if compgen -G "$CRYPTO_PREFIX/lib/$dep" > /dev/null; then
    for src in "$CRYPTO_PREFIX"/lib/$dep; do
      cp -a "$src" "$OUT_DIR/"
    done
  fi
done

echo "[gnutls-android] Verifying output ..."
file "$OUT_DIR/libgnutls.so"
"$READELF" -d "$OUT_DIR/libgnutls.so" | rg -n "NEEDED|SONAME" -S || true
echo "--- symbol check ---"
"$NM" -D "$OUT_DIR/libgnutls.so" | rg -n "gnutls_ecdh_compute_key|_gnutls_ecdh_compute_key" -S
echo "--- dependency check (must include libgmp.so.10) ---"
"$READELF" -d "$OUT_DIR/libgnutls.so" | rg -n "libgmp\\.so\\.10|libnettle\\.so|libhogweed\\.so" -S

echo "[gnutls-android] Done. Output:"
ls -lh "$OUT_DIR"
