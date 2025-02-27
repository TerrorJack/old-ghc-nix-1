{ stdenv, lib, patchelfUnstable
, perl, gcc, llvmPackages_5 ? null, llvmPackages_6 ? null
, llvmPackages_7 ? null, llvmPackages_9 ? null, llvmPackages_12 ? null, ncurses6, ncurses5, gmp, glibc, libiconv
, numactl ? null, elfutils
, which
}: { bindistTarballs, ncursesVersion, hosts, key, bindistVersion }:

# Prebuilt only does native
assert stdenv.targetPlatform == stdenv.hostPlatform;

let
  host = hosts.${stdenv.targetPlatform.system};

  libPath = lib.makeLibraryPath ([
    selectedNcurses gmp
  ] ++ lib.optional (stdenv.hostPlatform.isDarwin) libiconv
    ++ lib.optionals (stdenv.targetPlatform.isLinux) [ numactl elfutils ]);

  ncursesVersion = host.ncursesVersion or "6";

  selectedNcurses = {
    "5" = ncurses5;
    "6" = ncurses6;
  }."${ncursesVersion}";

  # Better way to do this? Just put this in versions.json
  selectedLLVM = {
    "9.2.1" = llvmPackages_12;
    "9.0.1" = llvmPackages_9;
    "8.10.7" = llvmPackages_12;
    "8.10.6" = llvmPackages_12;
    "8.10.5" = llvmPackages_12;
    "8.10.4" = llvmPackages_9;
    "8.10.3" = llvmPackages_9;
    "8.10.2" = llvmPackages_9;
    "8.10.1" = llvmPackages_9;
    "8.8.4" = llvmPackages_7;
    "8.8.3" = llvmPackages_7;
    "8.8.2" = llvmPackages_7;
    "8.8.1" = llvmPackages_7;
    "8.6.5" = llvmPackages_6;
    "8.6.4" = llvmPackages_6;
    "8.6.3" = llvmPackages_6;
    "8.6.2" = llvmPackages_6;
    "8.6.1" = llvmPackages_6;
    "8.4.4" = llvmPackages_5;
    "8.4.3" = llvmPackages_5;
    "8.4.2" = llvmPackages_5;
    "8.4.1" = llvmPackages_5;
    "8.2.2" = llvmPackages_5;
    "8.2.1" = llvmPackages_5;
    "8.0.2" = llvmPackages_5;
    "8.0.1" = llvmPackages_5;
  }."${bindistVersion}";

  libEnvVar = lib.optionalString stdenv.hostPlatform.isDarwin "DY"
    + "LD_LIBRARY_PATH";

  glibcDynLinker = assert stdenv.isLinux;
    if stdenv.hostPlatform.libc == "glibc" then
       # Could be stdenv.cc.bintools.dynamicLinker, keeping as-is to avoid rebuild.
       ''"$(cat $NIX_CC/nix-support/dynamic-linker)"''
    else
      "${lib.getLib glibc}/lib/ld-linux*";

  # Figure out version of bindist
  version =
    let
      helper = stdenv.mkDerivation {
        name = "bindist-version";
        src = bindistTarballs.${stdenv.targetPlatform.system};
        nativeBuildInputs = [ gcc perl ]
          ++ lib.optional (stdenv.targetPlatform.isLinux) elfutils;
        postUnpack = ''
          patchShebangs ghc*/utils/
          patchShebangs ghc*/configure
          sed -i 's@utils/ghc-pwd/dist-install/build/tmp/ghc-pwd-bindist@pwd@g' ghc*/configure
        '';

        patches =
          lib.optional stdenv.isDarwin ./patches/ghc844/darwin-gcc-version-fix.patch;

        buildPhase = ''
          # Run it twice since make might produce related output the first time.
          make show VALUE=ProjectVersion
          make show VALUE=ProjectVersion > version
        '';
        installPhase = ''
          source version
          echo -n "$ProjectVersion" > $out
        '';
      };
      hasBinDistVersion = bindistVersion != null;
      realVersion = lib.readFile helper;
    in if hasBinDistVersion then bindistVersion else throw "add ${key}.bindistVersion = \"${realVersion}\"; to hashes.nix";
in

stdenv.mkDerivation rec {
  inherit version;

  name = "ghc-${version}";

  src = bindistTarballs.${stdenv.targetPlatform.system};

  nativeBuildInputs = [ perl which ]
  ++ lib.optional (stdenv.targetPlatform.isLinux) elfutils;

  # Cannot patchelf beforehand due to relative RPATHs that anticipate
  # the final install location/
  ${libEnvVar} = libPath;

  postUnpack =
    # GHC has dtrace probes, which causes ld to try to open /usr/lib/libdtrace.dylib
    # during linking
    lib.optionalString stdenv.isDarwin ''
      export NIX_LDFLAGS+=" -no_dtrace_dof"
      # not enough room in the object files for the full path to libiconv :(
      for exe in $(find . -type f -executable); do
        isScript $exe && continue
        ln -fs ${libiconv}/lib/libiconv.dylib $(dirname $exe)/libiconv.dylib
        install_name_tool -change /usr/lib/libiconv.2.dylib @executable_path/libiconv.dylib -change /usr/local/lib/gcc/6/libgcc_s.1.dylib ${gcc.cc.lib}/lib/libgcc_s.1.dylib $exe
      done
    '' +

    # Some scripts used during the build need to have their shebangs patched
    ''
      patchShebangs ghc*/utils/
      patchShebangs ghc*/configure
    '' +

    # Strip is harmful, see also below. It's important that this happens
    # first. The GHC Cabal build system makes use of strip by default and
    # has hardcoded paths to /usr/bin/strip in many places. We replace
    # those below, making them point to our dummy script.
    ''
      mkdir "$TMP/bin"
      for i in strip; do
        echo '#! ${stdenv.shell}' > "$TMP/bin/$i"
        chmod +x "$TMP/bin/$i"
      done
      PATH="$TMP/bin:$PATH"
    '' +
    # We have to patch the GMP paths for the integer-gmp package.
    ''
      find . -name ghc-bignum.buildinfo \
          -exec sed -i "s@extra-lib-dirs: @extra-lib-dirs: ${gmp.out}/lib@" {} \;
      find . -name integer-gmp.buildinfo \
          -exec sed -i "s@extra-lib-dirs: @extra-lib-dirs: ${gmp.out}/lib@" {} \;
      find . -name terminfo.buildinfo \
          -exec sed -i "s@extra-lib-dirs: @extra-lib-dirs: ${selectedNcurses.out}/lib@" {} \;
    '' + lib.optionalString stdenv.isDarwin ''
      find . -name base.buildinfo \
          -exec sed -i "s@extra-lib-dirs: @extra-lib-dirs: ${libiconv}/lib@" {} \;
    '' +
    # Rename needed libraries and binaries, fix interpreter
    # N.B. Use patchelfUnstable due to https://github.com/NixOS/patchelf/pull/85
    lib.optionalString stdenv.isLinux ''
      find . -type f -perm -0100 -exec ${patchelfUnstable}/bin/patchelf \
          --replace-needed libncurses${lib.optionalString stdenv.is64bit "w"}.so.${ncursesVersion} libncurses.so \
          --replace-needed libtinfo.so.${ncursesVersion} libncurses.so.${ncursesVersion} \
          --interpreter ${glibcDynLinker} {} \;

      sed -i "s|/usr/bin/perl|perl\x00        |" ghc*/ghc/stage2/build/tmp/ghc-stage2
      sed -i "s|/usr/bin/gcc|gcc\x00        |" ghc*/ghc/stage2/build/tmp/ghc-stage2
    '';

  patches =
    lib.optional (version == "8.4.4" && stdenv.isDarwin) ./patches/ghc844/darwin-gcc-version-fix.patch;

  configurePlatforms = [ ];
  preConfigure = ''
    export CC=$(which $CC)
    export CXX=$(which $CXX)
    export LD=$(which $LD)
    export AS=$(which $AS)
    export AR=$(which $AR)
    export NM=$(which $NM)
    export RANLIB=$(which $RANLIB)
    export READELF=$(which $READELF)
    export STRIP=$(which $STRIP)
    export CLANG=${selectedLLVM.clang}/bin/clang
    export LLC=${selectedLLVM.llvm}/bin/llc
    export OPT=${selectedLLVM.llvm}/bin/opt
  '' + lib.optionalString (stdenv.targetPlatform.linker == "cctools") ''
    export OTOOL=$(which $OTOOL)
    export INSTALL_NAME_TOOL=$(which $INSTALL_NAME_TOOL)
  '';
  configureFlags = [
    "--with-gmp-libraries=${lib.getLib gmp}/lib"
    "--with-gmp-includes=${lib.getDev gmp}/include"
  ] ++ lib.optional stdenv.isDarwin "--with-gcc=${./gcc-clang-wrapper.sh}"
    ++ lib.optional stdenv.hostPlatform.isMusl "--disable-ld-override";

  # Stripping combined with patchelf breaks the executables (they die
  # with a segfault or the kernel even refuses the execve). (NIXPKGS-85)
  dontStrip = true;

  # No building is necessary, but calling make without flags ironically
  # calls install-strip ...
  dontBuild = true;

  # On Linux, use patchelf to modify the executables so that they can
  # find editline/gmp.
  preFixup = lib.optionalString stdenv.isLinux ''
    for p in $(find "$out" -type f -executable); do
      if isELF "$p"; then
        echo "Patchelfing $p"
        patchelf --set-rpath "${libPath}:$(patchelf --print-rpath $p)" $p
      fi
    done
  '' + lib.optionalString stdenv.isDarwin ''
    # not enough room in the object files for the full path to libiconv :(
    for exe in $(find "$out" -type f -executable); do
      isScript $exe && continue
      ln -fs ${libiconv}/lib/libiconv.dylib $(dirname $exe)/libiconv.dylib
      install_name_tool -change /usr/lib/libiconv.2.dylib @executable_path/libiconv.dylib -change /usr/local/lib/gcc/6/libgcc_s.1.dylib ${gcc.cc.lib}/lib/libgcc_s.1.dylib $exe
    done

    for file in $(find "$out" -name setup-config); do
      substituteInPlace $file --replace /usr/bin/ranlib "$(type -P ranlib)"
    done
  '' + ''
    for file in $(find "$out" -name settings); do
      substituteInPlace $file --replace '("ranlib command", "")' '("ranlib command", "ranlib")'
    done
  '';

  postInstall = lib.optionalString stdenv.isLinux ''
    # Fix dependencies on libtinfo in package registrations.
    for f in $(find "$out" -type f -iname '*.conf'); do
        echo "Fixing tinfo dependency in $f..."
        #sed -i "s/extra-libraries: *tinfo/extra-libraries: ncurses\n/" $f
        echo "library-dirs: ${selectedNcurses}/lib" >> $f
        echo "dynamic-library-dirs: ${selectedNcurses}/lib" >> $f
    done
    $out/bin/ghc-pkg recache
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    unset ${libEnvVar}
    # Sanity check, can ghc create executables?
    cd $TMP
    mkdir test-ghc; cd test-ghc
    cat > main.hs << EOF
      {-# LANGUAGE TemplateHaskell #-}
      module Main where
      main = putStrLn \$([|"yes"|])
    EOF
    $out/bin/ghc --make main.hs || exit 1
    echo compilation ok
    [ $(./main) == "yes" ]
  '';

  passthru = {
    targetPrefix = "";
    enableShared = true;
    haskellCompilerName = "ghc-${version}";
  };

  meta.license = lib.licenses.bsd3;
  meta.platforms = [ "i686-linux" "x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];
}
