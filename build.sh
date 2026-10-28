#!/bin/bash
#  build.sh - script to build a custom NDK toolchain
#
#  Copyright 2022 Chongyun Lee <uchkks@protonmail.com>
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#	http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

set -e -u -o pipefail

_SCRIPTDIR=$(cd "$(realpath "$(dirname "$0")")"; pwd)
source $_SCRIPTDIR/common-files/setup_toolchain_ndk_r17c.sh
source $_SCRIPTDIR/common-files/termux_download.sh

: ${TOOLCHAIN_ARCH:=aarch64}
: ${_CACHE_DIR:=$_SCRIPTDIR/cache}
: ${_TMP_DIR:=$_SCRIPTDIR/tmp}
# Persistent build workspace: artifacts survive re-runs so finished stages
# can be skipped. Stamps live under work/.stamps/.
: ${_BUILD_DIR:=$_SCRIPTDIR/work}
: ${_STATE_DIR:=$_SCRIPTDIR/work/.stamps}
: ${_API_LEVEL:=21}
: ${_MAKE_PROCESSES:=$(nproc)}
: ${GCC_VERSION:=14.4.0}
: ${GCC_SHA256:=f35aa1c7f14e6bbe5a7fab83abcb7813449aa1dc6d38bbf27b74614dee17db5e}
: ${BINUTILS_VERSION:=2.46.1}
: ${BINUTILS_SHA256:=364c8faa19ea46c44089c2d59c1fee6eda9a273787d0fe8ab9dfb249069c6aee}

export TOOLCHAIN_ARCH

TERMUX_PKG_TMPDIR=$_TMP_DIR
mkdir -p $_CACHE_DIR $_BUILD_DIR $_STATE_DIR
# Only the tmp dir is wiped; build artifacts in $_BUILD_DIR are preserved
# across runs so finished stages can be skipped.
rm -rf $_TMP_DIR
mkdir -p $_TMP_DIR

_HOST_PLATFORM="${TOOLCHAIN_ARCH}-linux-android"

_GCC_EXTRA_HOST_BUILD=""
_BINUTILS_EXTRA_HOST_BUILD="--enable-gold"
if [ "$TOOLCHAIN_ARCH" = "arm" ]; then
	_HOST_PLATFORM="${_HOST_PLATFORM}eabi"
	_GCC_EXTRA_HOST_BUILD="--with-arch=armv7-a --with-float=soft --with-fpu=vfp"
elif [ "$TOOLCHAIN_ARCH" = "aarch64" ]; then
	_GCC_EXTRA_HOST_BUILD="--enable-fix-cortex-a53-835769 --enable-fix-cortex-a53-843419"
	_BINUTILS_EXTRA_HOST_BUILD+=" $_GCC_EXTRA_HOST_BUILD"
elif [ "$TOOLCHAIN_ARCH" = "i686" ]; then
	_GCC_EXTRA_HOST_BUILD="--with-arch=i686 --with-fpmath=sse "
elif [ "$TOOLCHAIN_ARCH" = "x86_64" ]; then
	_GCC_EXTRA_HOST_BUILD="--with-arch=x86-64 --with-fpmath=sse"
fi

# Stamp suffix includes everything that affects build output, so changing any
# of them (binutils/gcc version, arch, API level) forces the relevant rebuild.
_STAMP_SUFFIX="${BINUTILS_VERSION}-${GCC_VERSION}-${TOOLCHAIN_ARCH}-api${_API_LEVEL}"

# Return success if the given build stage is already finished and its artifact
# still exists, so the caller can skip re-running it.
_stage_done() {
	local stage="$1"
	local artifact="$2"
	local stamp="$_STATE_DIR/.stamp-${stage}-${_STAMP_SUFFIX}"
	if [ -f "$stamp" ] && [ -e "$artifact" ]; then
		echo "==> Stage '$stage' already built, skipping."
		return 0
	fi
	return 1
}

# Mark a build stage as finished by touching its stamp file.
_mark_stage_done() {
	local stage="$1"
	local stamp="$_STATE_DIR/.stamp-${stage}-${_STAMP_SUFFIX}"
	touch "$stamp"
}

# Install dependencies
sudo apt update
sudo apt install -y build-essential curl
sudo apt install -y libgmp-dev libmpfr-dev libmpc-dev zlib1g-dev libisl-dev libncurses-dev

pushd $_TMP_DIR

# Download source (skipped automatically when cached file matches its checksum)
GCC_SRC_URL=https://mirrors.kernel.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.gz
GCC_SRC_FILE=$_CACHE_DIR/gcc-${GCC_VERSION}.tar.gz
GCC_SRC_DIR=$_TMP_DIR/gcc-${GCC_VERSION}
termux_download $GCC_SRC_URL $GCC_SRC_FILE $GCC_SHA256
BINUTILS_SRC_URL=https://mirrors.kernel.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.gz
BINUTILS_SRC_FILE=$_CACHE_DIR/binutils-${BINUTILS_VERSION}.tar.gz
BINUTILS_SRC_DIR=$_TMP_DIR/binutils-${BINUTILS_VERSION}
termux_download $BINUTILS_SRC_URL $BINUTILS_SRC_FILE $BINUTILS_SHA256

# Install prefix shared by binutils and gcc stages (kept in the persistent dir).
_PREFIX=$_BUILD_DIR/newer-toolchain

# ---------------------------------------------------------------------------
# Stage 1: prepare the toolchain base (standalone toolchain + sysroot).
# Creates $_PREFIX (newer-toolchain) with the NDK sysroot. Rebuilding it wipes
# the whole prefix, so later stages are re-triggered automatically (their stamp
# check also requires the artifact to still exist).
# ---------------------------------------------------------------------------
if ! _stage_done sysroot "$_PREFIX/sysroot"; then
	rm -rf "$_PREFIX" "$_BUILD_DIR/binutils-build" "$_BUILD_DIR/newer-toolchain-build"

	# Setup a standalone toolchain
	_setup_standalone_toolchain_ndk_r17c $_TMP_DIR/standalone-toolchain
	cp -R $_TMP_DIR/standalone-toolchain/sysroot/usr/include/$_HOST_PLATFORM/* $_TMP_DIR/standalone-toolchain/sysroot/usr/include/

	# Copy sysroot into the persistent prefix
	mkdir -p $_PREFIX
	cp -R $_TMP_DIR/standalone-toolchain/sysroot $_PREFIX/

	_mark_stage_done sysroot
fi

# ---------------------------------------------------------------------------
# Stage 2: binutils.
# Skipped when binutils was already built successfully for this version/arch.
# ---------------------------------------------------------------------------
if ! _stage_done binutils "$_PREFIX/bin/$_HOST_PLATFORM-ld"; then
	rm -rf "$_BUILD_DIR/binutils-build"

	# Extract binutils source
	tar -xf $BINUTILS_SRC_FILE -C $_TMP_DIR/

	# Set CPPFLAGS/CFLAGS/CXXFLAGS
	export CPPFLAGS="-O3 -g0"
	export CFLAGS="$CPPFLAGS"
	export CXXFLAGS="$CPPFLAGS"

	# Build binutils
	mkdir -p $_BUILD_DIR/binutils-build
	pushd $_BUILD_DIR/binutils-build
	$BINUTILS_SRC_DIR/configure \
			--target=$_HOST_PLATFORM \
			--prefix=$_PREFIX \
			--with-sysroot=$_PREFIX/sysroot \
			--with-zstd \
			ZSTD_LIBS=-l:libzstd.a \
			$_BINUTILS_EXTRA_HOST_BUILD
	make -j $_MAKE_PROCESSES
	make -j $_MAKE_PROCESSES install-strip
	popd # binutils-build

	_mark_stage_done binutils
fi

# The gcc stage needs binutils on PATH whether or not binutils was just rebuilt.
export PATH="$_PREFIX/bin:$PATH"

# ---------------------------------------------------------------------------
# Stage 3: GCC.
# Skipped when gcc was already built successfully for this version/arch.
# ---------------------------------------------------------------------------
if ! _stage_done gcc "$_PREFIX/bin/$_HOST_PLATFORM-gcc"; then
	# Only the gcc build dir is wiped; the prefix (with binutils) is kept.
	rm -rf "$_BUILD_DIR/newer-toolchain-build"

	# Extract GCC source
	tar -xf $GCC_SRC_FILE -C $_TMP_DIR/

	# Apply patches (all patches target the gcc source tree)
	PATCHES="$(find "$_SCRIPTDIR/patches/" -maxdepth 1 -type f -name *.patch | sort)"
	for f in $PATCHES; do
		echo "Applying patch: $(basename $f)"
		patch -d "$GCC_SRC_DIR/" -p1 < "$f";
	done

	# Set CPPFLAGS/CFLAGS/CXXFLAGS (base + Android API level)
	export CPPFLAGS="-O3 -g0 -D__ANDROID_API__=$_API_LEVEL"
	export CFLAGS="$CPPFLAGS"
	export CXXFLAGS="$CPPFLAGS"

	# Build GCC toolchain
	mkdir -p $_BUILD_DIR/newer-toolchain-build
	pushd $_BUILD_DIR/newer-toolchain-build

	$GCC_SRC_DIR/configure \
			--host=x86_64-linux-gnu  \
			--build=x86_64-linux-gnu \
			--target=$_HOST_PLATFORM \
			--disable-shared \
			--disable-nls \
			--enable-default-pie \
			--with-host-libstdcxx='-static-libgcc -Wl,-Bstatic,-lstdc++,-Bdynamic -lm' \
			--with-gnu-as --with-gnu-ld \
			--disable-libstdc__-v3 \
			--disable-tls \
			--disable-ssp \
			--disable-bootstrap \
			--enable-initfini-array \
			--enable-libatomic-ifuncs=no \
			--prefix=$_PREFIX \
			--with-gmp --with-mpfr --with-mpc --with-system-zlib \
			--enable-languages=c,c++,fortran \
			--enable-plugins --enable-libgomp \
			--enable-gnu-indirect-function \
			--disable-libcilkrts --disable-libsanitizer \
			--enable-gold --enable-threads \
			--enable-eh-frame-hdr-for-static \
			--enable-graphite=yes --with-isl \
			--disable-multilib \
			$_GCC_EXTRA_HOST_BUILD \
			--with-sysroot=$_PREFIX/sysroot \
			--with-gxx-include-dir=$_PREFIX/include/c++/$GCC_VERSION

	make -j $_MAKE_PROCESSES
	make -j $_MAKE_PROCESSES install-strip

	popd # newer-toolchain-build

	_mark_stage_done gcc
fi

popd # $_TMP_DIR

# ---------------------------------------------------------------------------
# Stage 4: package the toolchain archive.
# Skipped when the archive was already built (stamp + file both present).
# ---------------------------------------------------------------------------
_ARCHIVE_NAME="gcc-$GCC_VERSION-$TOOLCHAIN_ARCH"
_ARCHIVE_DIR=$_SCRIPTDIR/build
_ARCHIVE_FILE=$_ARCHIVE_DIR/$_ARCHIVE_NAME.tar.bz2

if _stage_done archive "$_ARCHIVE_FILE"; then
	: # already packaged
else
	mkdir -p "$_ARCHIVE_DIR"
	# Pack the prefix in place (renamed via --transform) without moving it,
	# so the prefix stays available for future incremental rebuilds.
	tar -cjvf "$_ARCHIVE_FILE" -C "$_BUILD_DIR" \
		--transform "s/^newer-toolchain/$_ARCHIVE_NAME/" newer-toolchain
	_mark_stage_done archive
fi
