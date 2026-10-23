Name:           aubade
Version:        1.0.0
Release:        1%{?dist}
Summary:        from an audiophile to an audiophile. a local first music player
License:        MIT
URL:            https://github.com/workbydivyanshu/aubade-music-player
BuildArch:      x86_64

%global __strip /bin/true
%define debug_package %{nil}
AutoReqProv:    no

Requires:       gtk3
Requires:       mpv-libs
Requires:       alsa-lib
Requires:       keybinder3

%description
from an audiophile to an audiophile. a local first music player

%prep

%build

%install
rm -rf "%{buildroot}"
mkdir -p "%{buildroot}/opt/aubade"
mkdir -p "%{buildroot}/usr/bin"
mkdir -p "%{buildroot}/usr/share/applications"
mkdir -p "%{buildroot}/usr/share/pixmaps"

cp -r "%{_sourcedir}/bundle/." "%{buildroot}/opt/aubade/"
chmod +x "%{buildroot}/opt/aubade/aubade"

cat << 'LAUNCHER' > "%{buildroot}/usr/bin/aubade"
#!/usr/bin/bash
APP_DIR="/opt/aubade"
export LD_LIBRARY_PATH="$APP_DIR/lib:${LD_LIBRARY_PATH:-}"
exec "$APP_DIR/aubade" "$@"
LAUNCHER
chmod +x "%{buildroot}/usr/bin/aubade"

cp "%{_sourcedir}/aubade.desktop" "%{buildroot}/usr/share/applications/aubade.desktop"

# Dolphin / Konqueror "Open in Aubade" service menu. KIO ignores
# service menu files that are not executable.
mkdir -p "%{buildroot}/usr/share/kio/servicemenus"
cp "%{_sourcedir}/aubade-servicemenu.desktop" "%{buildroot}/usr/share/kio/servicemenus/aubade-servicemenu.desktop"
chmod +x "%{buildroot}/usr/share/kio/servicemenus/aubade-servicemenu.desktop"

# Multi-resolution hicolor icon suite (16x16 up to 512x512)
for sz in 16 24 32 48 64 128 256 512; do
  mkdir -p "%{buildroot}/usr/share/icons/hicolor/${sz}x${sz}/apps"
  cp "%{_sourcedir}/icons/${sz}x${sz}/aubade.png" "%{buildroot}/usr/share/icons/hicolor/${sz}x${sz}/apps/aubade.png"
  cp "%{_sourcedir}/icons/${sz}x${sz}/com.aubade.desktop.png" "%{buildroot}/usr/share/icons/hicolor/${sz}x${sz}/apps/com.aubade.desktop.png"
done

# Fallback pixmaps for all window managers and custom themes
cp "%{_sourcedir}/icons/512x512/aubade.png" "%{buildroot}/usr/share/pixmaps/aubade.png"
cp "%{_sourcedir}/icons/512x512/com.aubade.desktop.png" "%{buildroot}/usr/share/pixmaps/com.aubade.desktop.png"

%files
/opt/aubade
/usr/bin/aubade
/usr/share/applications/aubade.desktop
/usr/share/kio/servicemenus/aubade-servicemenu.desktop
/usr/share/icons/hicolor/*/apps/aubade.png
/usr/share/icons/hicolor/*/apps/com.aubade.desktop.png
/usr/share/pixmaps/aubade.png
/usr/share/pixmaps/com.aubade.desktop.png

%post
/usr/bin/update-desktop-database &> /dev/null || :
/bin/touch --no-create /usr/share/icons/hicolor &>/dev/null || :
/usr/bin/gtk-update-icon-cache -f -t /usr/share/icons/hicolor &>/dev/null || :

%postun
/usr/bin/update-desktop-database &> /dev/null || :
/bin/touch --no-create /usr/share/icons/hicolor &>/dev/null || :
/usr/bin/gtk-update-icon-cache -f -t /usr/share/icons/hicolor &>/dev/null || :

%changelog
* Tue Oct 20 2026 Aubade Desktop Team - 1.0.0-1
- Initial public release of Aubade Music Player v1.0.0
- Bit-perfect lossless audio pipeline with live stream telemetry HUD
- Liquid glass UI, dynamic artwork aura, and floating island player dock
- High-speed Tauon-grade local library scanner with companion artwork & .lrc sidecar persistence
- Zero-telemetry Listening Vault analytics and offline Last.fm scrobble queue
- Discord Rich Presence daemon via raw Unix / Windows named pipe IPC
- Native in-app auto-update notifications and direct installer integration
* Tue Oct 20 2026 Aubade Desktop Team - 0.01.09-1
- Discord presence rebuilt on the raw IPC daemon design: 5s push throttle, rate-limit backoff, reply drain, and zombie-safe connection drops
* Mon Oct 19 2026 Aubade Desktop Team - 0.01.08-1
- Apple-caliber Aubade glassy prism branding and full-resolution hicolor icon suite
- Unified spotlight search with Raycast-style actions, ambient dynamic artwork, and floating glass dock
