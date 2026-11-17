#!/bin/bash
set -euo pipefail

set_variables() {
	N='\e[0m'           #reset all formattings
    B='\e[1m'           #normal (bolded)
	R='\e[1;31m'        #red (bolded)
	O='\e[1;38;5;214m'  #orange (bolded)
	G='\e[1;32m'        #green (bolded)

	E="${R}[ ERROR ]${N} " #Error Dialog
	W="${O}[WARNING]${N} " #Warning Dialong
	L="${B}[  LOG  ]${N} " #Log Dialog
	S="${G}[SUCCESS]${N} " #Success Dialog
	
}

safety_wrappers() {
	# Save the original dir
	ORIGINAL_DIR="$(pwd)"

	# Make a temp dir
	TMP=$(mktemp -d)
	cd "$TMP"

	# Trap to restore dir and cleanup on exit
	trap 'cd "$ORIGINAL_DIR" 2>/dev/null || true; rm -rf "${TMP:-}" 2>/dev/null || true' EXIT

	# Log file
	LOGFILE="$HOME/.MacOSthemeAutoInstallScript.log"
	# Append all stdout/stderr to the logfile while also showing it on the console
	exec > >(tee -a "$LOGFILE") 2>&1
}

check_compatible() {   
    # Ensure the OS release file exists
    if [ ! -f /etc/os-release ]; then
        echo -e "${E}Could not determine the operating system." >&2
        exit 1
    fi
    
    # Load OS variables
    . /etc/os-release

    # Check for Ubuntu
    if [ "$ID" != "ubuntu" ]; then    
        echo -e "${E}This script is only intended for Ubuntu. Current OS: $NAME" >&2
        exit 1
    fi

    # Check for GNOME
    if [ "$XDG_CURRENT_DESKTOP" != "GNOME" ] && [ "$XDG_CURRENT_DESKTOP" != "ubuntu:GNOME" ]; then
        echo -e "${E}This script requires the GNOME desktop environment." >&2
        exit 1
    fi

    # Check for Wayland
    if [ "$XDG_SESSION_TYPE" != "wayland" ]; then
        echo -e "${E}This script requires a Wayland session." >&2
        exit 1
    fi
    
    echo -e "${S}Environment verified: ubuntu with GNOME on Wayland. Proceeding..."

    if command -v curl &> /dev/null; then
		echo -e "${S}curl exists. Proceeding.."
	else
		echo -e "${W}curl doesn't exist. installing..."
		sudo apt -qq -y install curl || {
			echo -e "${E}Failed to install curl via apt."
			exit 1
		}
		echo -e "${S}curl installed. Proceeding..."
	fi
	
	if ! curl --connect-timeout 5 -sI https://github.com &> /dev/null; then
        echo -e "${E}This script requires an active internet connection."
        exit 1
    fi

}

install_required_softs() {

	local REPOS=(
		"universe"
		"ppa:agornostal/ulauncher"
	)

	  for repo in "${REPOS[@]}"; do
        echo -e "${L}Adding apt repository $repo..."
        sudo add-apt-repository "$repo" -y -n || { #use -n option to prevent updating after adding the repo
			echo -e "${E}Failed to add repository $repo"
			echo -e "${L}Continuing anyways..."
    		continue
        }
      done

    local REQUIRED_PACKAGES=(
        appmenu-gtk3-module
        jq
        unzip
        build-essential
        procps
        file
        pipx
        bamfdaemon
        gir1.2-bamf-3
        libbamf3-2
        libkeybinder-3.0-0
        gir1.2-keybinder-3.0
        unity-gtk-module-common
        python3-pip
        python3-venv
        gnome-shell
        gnome-tweaks
        timeshift
        flatpak
        git
        sassc
        libglib2.0-dev-bin
        libxml2-utils
        imagemagick
        dialog
        optipng
        inkscape
        dconf-cli
        gnome-sushi
        ulauncher
		make
		python3-setuptools
        gnome-shell-extension-autohidetopbar #autohide top bar extension
        )
    
    sudo apt -q update
    
    for package in "${REQUIRED_PACKAGES[@]}"; do
        echo -e "${L}Installing software $package..."
        sudo apt -qq -y install "$package" &> /dev/null && echo -e "${L}Package $package is installled. moving to the next one... " || {
          echo -e "${E}Failed to install package $package"
		  echo -e "${L}Continuing anyways..."
          continue
        }
      done
    
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    
    flatpak install -y flathub com.mattjakeman.ExtensionManager || {
		echo -e "${E}Failed to install ExtensionManager"
		echo -e "${E}Continuing anyways..."
		}



    pipx ensurepath
    export PATH="$PATH:$HOME/.local/bin"

    sudo pip install future fuzzysearch --break-system-packages || {
        echo -e "${W}pip install failed (possibly unsupported on this pip version). Continuing..."
    }
    
    if ! command -v gext &> /dev/null; then
        echo -e "${W}gext not found. Installing..."
        pipx install gnome-extensions-cli --system-site-packages || {
            echo -e "${E}gext installation failed!" >&2
            exit 1
        }
        sleep 2  # wait for install to settle
    
        if command -v gext &> /dev/null; then
            echo -e "${S}gext installed successfully."
        else
            echo -e "${E}gext installation failed!" >&2
            echo -e "${L}Restarting the terminal might help" >&2
            exit 1
        fi
    fi

}

configure_firefox() {
	
	while true; do
 	   read -r -p "Do you agree to kill firefox for theme installation? " yn
	    case $yn in
	        [Yy]* ) pkill firefox || true 
			break ;;
	        [Nn]* ) exit 0 ;;
	        * ) echo "Please answer yes or no." ;;
	    esac
	done
	    
    # Wait for Firefox to fully exit before touching prefs.js
    for i in {1..10}; do
        pgrep -f firefox &> /dev/null || break
        echo -e "${L}Waiting for firefox to be killed... ($i/10)"
        sleep 1
    done
    
    if command -v firefox &> /dev/null; then
        echo -e "${L}Firefox is found. proceeding..."
    else
        echo -e "${E}Firefox is not installed."
        exit 1
    fi

    PROFILE_DIR="$HOME/snap/firefox/common/.mozilla/firefox"

    # Fallback for classic APT installation if Snap directory doesn't exist
    if [ ! -d "$PROFILE_DIR" ]; then
        PROFILE_DIR="$HOME/.mozilla/firefox"
    fi

    # Locate the primary user profile folder
    # (Looks for folders ending in .default-release or .default)
    USER_PROFILE=$(find "$PROFILE_DIR" -maxdepth 1 -type d \( -name "*.default-release" -o -name "*.default" \) | head -n 1)    

    #Verify the profile and check the onboarding status
    if [ -z "$USER_PROFILE" ] || [ ! -f "$USER_PROFILE/prefs.js" ]; then
        echo -e "${E}Firefox profile has not been created yet. Launch Firefox once first." >&2
        exit 1
    fi

    echo -e "${L}Configuring required Firefox flags..."

    # Define the flags to enable
    declare -A FIREFOX_FLAGS=(
        ["layers.acceleration.force-enabled"]="true"
        ["toolkit.legacyUserProfileCustomizations.stylesheets"]="true"
        ["browser.tabs.allowTabCloseOnMiddleClick"]="false"
    )

    for flag in "${!FIREFOX_FLAGS[@]}"; do
        value="${FIREFOX_FLAGS[$flag]}"
        escaped_flag="${flag//./\\.}"

        # Check if flag already exists
        if grep -q "^user_pref(\"$flag\"" "$USER_PROFILE/prefs.js"; then
            # Update existing flag
            sed -i "s/^user_pref(\"$escaped_flag\", .*);/user_pref(\"$flag\", $value);/" "$USER_PROFILE/prefs.js" || {
                echo -e "${E}Failed to update Firefox flag $flag" >&2
                exit 1
            }
        else
            # Append new flag
            echo -e "user_pref(\"$flag\", $value);" >> "$USER_PROFILE/prefs.js" || {
                echo -e "${E}Failed to append Firefox flag $flag" >&2
                exit 1
            }
        fi
    done
    
}

install_gnome_extensions() {
    local extensions=(
        dash-to-dock@micxgx.gmail.com
		Rounded_Corners@lennart-k
		gnome-ui-tune@itstime.tech
		space-bar@luchrioh
		user-theme@gnome-shell-extensions.gcampax.github.com
		compiz-alike-magic-lamp-effect@hermes83.github.com
		tiling-assistant@leleat-on-github
		CoverflowAltTab@palatis.blogspot.com
		rounded-windows@marcosgt.github.io
		gsconnect@andyholmes.github.io
		Bluetooth-Battery-Meter@maniacx.github.com
		blur-my-shell@aunetx
		auto-move-windows@gnome-shell-extensions.gcampax.github.com
		top-bar-organizer@julian.gse.jsts.xyz
		caffeine@patapon.info
		wiggly@mojarch
		just-perfection-desktop@just-perfection
		#hidetopbar-fixed@local installednvia apt using package gnome-shell-extension-autohidetopbar
		notification-banner-re-reloaded@chrhuang
		widgets@distro.com
		appindicatorsupport@rgcjonas.gmail.com
		#global-menu@unmade.space installed via terminal
		clipboard-indicator@tudmotu.com
		kiwimenu@kemma
		kiwi@kemma
      )
  
      for ext in "${extensions[@]}"; do
        echo -e "${L}Installing extension $ext..."
        gext install "$ext" || {
          echo -e "${E}Failed to install extension $ext."
          echo -e "${L}Continuing anyways..."
          continue
        }
        gext enable "$ext" || {
          echo -e "${E}Failed to enable extension $ext."
		  echo -e "${L}This is possibly due to wayland restraints."
		  echo -e "${L}Logout and log back in before running the script again may help."
          echo -e "${L}Continuing anyways..."
        }
      done

      gext disable ubuntu-dock@ubuntu.com || true
}

install_theme() {
    # Save current directory and use subshell to prevent directory pollution
    local theme_work_dir
    theme_work_dir="$TMP/theme_install_$$"
    mkdir -p "$theme_work_dir"
    
        cd "$theme_work_dir" || exit 1
        
        git clone https://github.com/vinceliuice/MacTahoe-gtk-theme.git --depth=1 || {
            echo -e "${E}Failed to clone MacTahoe-gtk-theme" >&2
            exit 1
        }
        sudo "$theme_work_dir"/MacTahoe-gtk-theme/install.sh -o normal -b --shell -i apple -h smaller -sf  -ns --round --silent-mode || {
            echo -e "${E}Failed to install MacTahoe-gtk-theme" >&2
            exit 1
        }
        "$theme_work_dir"/MacTahoe-gtk-theme/install.sh -l -o normal -b --shell -i apple -h smaller -sf --round --silent-mode || {
            echo -e "${E}Failed to configure MacTahoe-gtk-theme for libadwaita" >&2
            exit 1
        }
        "$theme_work_dir"/MacTahoe-gtk-theme/wallpaper/install-gnome-backgrounds.sh || {
            echo -e "${E}Failed to install wallpapers."
            echo -e "${L}Proceding anyways..."
        }
        sudo "$theme_work_dir"/MacTahoe-gtk-theme/tweaks.sh -g -sf -nd -nb --silent-mode || {
            echo -e "${E}Failed to apply tweaks (step 1)" >&2
            exit 1
        }
        "$theme_work_dir"/MacTahoe-gtk-theme/tweaks.sh -f --silent-mode || {
            echo -e "${E}Failed to apply tweaks (step 2)" >&2
            exit 1
        }
        
        "$theme_work_dir"/MacTahoe-gtk-theme/tweaks.sh -f adaptive --silent-mode 2>/dev/null

        sudo flatpak override --filesystem=xdg-config/gtk-3.0 && sudo flatpak override --filesystem=xdg-config/gtk-4.0 || {
            echo -e "${E}failed to override Flatpak theme"
            exit 1
        }
        "$theme_work_dir"/MacTahoe-gtk-theme/tweaks.sh -F -c Dark --silent-mode || {
            echo -e "${E}Failed to apply tweaks (step 4)" >&2
            exit 1
        }
        "$theme_work_dir"/MacTahoe-gtk-theme/tweaks.sh -d --silent-mode || {
            echo -e "${E}Failed to apply tweaks (step 5)" >&2
            exit 1
        }

        git clone https://github.com/vinceliuice/MacTahoe-icon-theme.git --depth=1 || {
            echo -e "${E}Failed to clone MacTahoe-icon-theme" >&2
            exit 1
        }
		
        "$theme_work_dir"/MacTahoe-icon-theme/install.sh -b || {
            echo -e "${E}Failed to install MacTahoe-icon-theme" >&2
            exit 1
        }

        sudo "$theme_work_dir"/MacTahoe-icon-theme/cursors/install.sh || {
            echo -e "${E}Failed to install cursors" >&2
            exit 1
        }

		mkdir -p "$HOME/.local/share/gnome-shell/extensions/"
		git clone https://github.com/Unmade760/orbit-global-menu.git || {
			echo -e "${E}Failed to clone orbit-global-menu" >&2
			exit 1
		}
		cd "$theme_work_dir"/orbit-global-menu || exit 1

		cp -r 'global-menu@unmade.space' "$HOME/.local/share/gnome-shell/extensions/" || {
			echo -e "${E}Failed to copy global-menu extension" >&2
			exit 1
		}
		glib-compile-schemas "$HOME/.local/share/gnome-shell/extensions/global-menu@unmade.space/schemas" || {
			echo -e "${E}Failed to compile global-menu schemas" >&2
			exit 1
		}

		gext enable global-menu@unmade.space || {
			echo -e "${E}Failed to enable extension global-menu@unmade.space."
			echo -e "${L}This is possibly due to wayland restraints."
			echo -e "${L}Logout and log back in before running the script again may help."
    		echo -e "${L}Continuing anyways..."
		}

		cd "$theme_work_dir/orbit-global-menu"

		make build || {
			echo -e "${E}Failed to build orbit-global-menu" >&2
			exit 1
		}
		sudo apt -q -y install ./global-menu_*.deb || {
			echo -e "${E}Failed to install global-menu deb" >&2
			exit 1
		}

        cd "$theme_work_dir"
}

apply_settings() {
	#apply setting for gnome tweak managed settings (work-in-progress)
	gsettings set org.gnome.desktop.interface gtk-theme "MacTahoe-Dark"
	gsettings set org.gnome.desktop.interface icon-theme "MacTahoe-dark"
	gsettings set org.gnome.desktop.interface cursor-theme "MacTahoe-cursors"
	gsettings set org.gnome.desktop.interface color-scheme "prefer-dark"
	gsettings set org.gnome.desktop.wm.preferences button-layout 'close,maximize,minimize:'

	
	#apply user themes
	gsettings set org.gnome.shell.extensions.user-theme name "MacTahoe-Dark"

    dbus-run-session -- gnome-shell --nested --wayland #reload wayland session
}

main() {
	set_variables
	safety_wrappers
    check_compatible
    install_required_softs
    configure_firefox
    install_gnome_extensions
    install_theme
    apply_settings
}

main
