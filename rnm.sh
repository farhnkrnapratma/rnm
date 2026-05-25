#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s globstar nullglob extglob

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
LOG_DIR=""
LOG_FILE=""

DRY_RUN=0
ACTION=""
CASE_STYLE="kebab-case"
CASE_FROM_CLI=0
INSTALL_COMPLETIONS="detect"
INSTALL_COMPLETIONS_FROM_CLI=0
DISABLE_LOG=0
DISABLE_LOG_FROM_CLI=0
ROLLBACK_SCRIPT=""
TARGET_DIR=""
declare -a REQUESTED_PATHS=()
declare -a RENAME_OLD_PATHS=()
declare -a RENAME_NEW_PATHS=()
declare -a EXCLUDE_PATTERNS=(
	".git"
	"LICENSE*"
	"README*"
)
declare -a INCLUDE_PATTERNS=()
COLOR_STDOUT=false
COLOR_STDERR=false
C_RESET=""
C_INFO=""
C_SKIP=""
C_RENAME=""
C_DRY=""
E_RESET=""
E_ERROR=""
RUN_STARTED_AT=""
RUN_STARTED_EPOCH=""
RUN_COMMAND=""
LOGGING_READY=0

init_colors() {
	if [[ -t 1 && -z ${NO_COLOR-} ]]; then
		COLOR_STDOUT=true
		C_RESET="$(tput sgr0 2>/dev/null || true)"
		C_INFO="$(tput bold 2>/dev/null || true)"
		C_SKIP="$(tput bold 2>/dev/null || true)"
		C_RENAME="$(tput bold 2>/dev/null || true)"
		C_DRY="$(tput bold 2>/dev/null || true)"
	fi

	if [[ -t 2 && -z ${NO_COLOR-} ]]; then
		COLOR_STDERR=true
		E_RESET="$(tput sgr0 2>/dev/null || true)"
		E_ERROR="$(tput bold 2>/dev/null || true)"
	fi
}

fatal_before_logging() {
	printf 'rnm: %s\n' "$*" >&2
	exit 1
}

write_log_file() {
	local level="$1"
	shift

	if [[ $LOGGING_READY -eq 1 ]]; then
		printf '%s: %s\n' "$level" "$*" >>"$LOG_FILE"
	fi
}

format_command() {
	local arg quoted output=""
	for arg in "$@"; do
		printf -v quoted '%q' "$arg"
		if [[ -n $output ]]; then
			output+=" "
		fi
		output+="$quoted"
	done
	printf '%s\n' "$output"
}

init_logging() {
	if [[ $DISABLE_LOG -eq 1 ]]; then
		LOGGING_READY=0
		return 0
	fi
	LOG_DIR="$(get_xdg_state_home)/rnm"
	LOG_FILE="$LOG_DIR/rnm-$(date +%Y%m%d).log"
	[[ $LOG_DIR == /* ]] || fatal_before_logging "log directory must be absolute: $LOG_DIR"
	[[ $LOG_DIR != *"/../"* && $LOG_DIR != */.. ]] || fatal_before_logging "log directory must not contain ..: $LOG_DIR"
	umask 077
	if path_exists "$LOG_DIR"; then
		if [[ -L $LOG_DIR || ! -d $LOG_DIR || ! -O $LOG_DIR ]]; then
			fatal_before_logging "unsafe log directory: $LOG_DIR"
		fi
		if is_group_or_other_accessible "$LOG_DIR"; then
			fatal_before_logging "log directory is accessible by group or others: $LOG_DIR"
		fi
	else
		install -d -m 0700 -- "$LOG_DIR"
	fi
	if [[ -L $LOG_DIR || ! -d $LOG_DIR || ! -O $LOG_DIR ]] || is_group_or_other_accessible "$LOG_DIR"; then
		fatal_before_logging "unsafe log directory after creation: $LOG_DIR"
	fi
	if path_exists "$LOG_FILE"; then
		if [[ -L $LOG_FILE || ! -f $LOG_FILE || ! -O $LOG_FILE ]]; then
			fatal_before_logging "unsafe log file: $LOG_FILE"
		fi
	fi
	: >"$LOG_FILE"
	LOGGING_READY=1
}

write_log_header() {
	[[ $DISABLE_LOG -eq 0 ]] || return 0
	local user host uid gid cwd shell_name
	RUN_STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S %z')"
	RUN_STARTED_EPOCH="$(date +%s)"
	user="${USER:-$(id -un 2>/dev/null || printf unknown)}"
	uid="${UID:-$(id -u)}"
	gid="$(id -g 2>/dev/null || printf unknown)"
	host="$(hostname 2>/dev/null || printf unknown)"
	cwd="$(pwd -P 2>/dev/null || pwd)"
	shell_name="${SHELL:-unknown}"
	{
		printf '%s\n' '----- rnm log start -----'
		printf 'tool: %s\n' "$SCRIPT_NAME"
		printf 'user: %s\n' "$user"
		printf 'uid: %s\n' "$uid"
		printf 'gid: %s\n' "$gid"
		printf 'host: %s\n' "$host"
		printf 'pid: %s\n' "$$"
		printf 'cwd: %s\n' "$cwd"
		printf 'shell: %s\n' "$shell_name"
		printf 'started_at: %s\n' "$RUN_STARTED_AT"
		printf 'command: %s\n' "$RUN_COMMAND"
		printf 'log_file: %s\n' "$LOG_FILE"
		printf '%s\n' '-------------------------'
	} >>"$LOG_FILE"
}

write_log_footer() {
	[[ $DISABLE_LOG -eq 0 && $LOGGING_READY -eq 1 ]] || return 0
	local exit_code="$1"
	local finished_at finished_epoch duration

	[[ $LOGGING_READY -eq 1 ]] || return 0
	finished_at="$(date '+%Y-%m-%d %H:%M:%S %z')"
	finished_epoch="$(date +%s)"
	if [[ -n $RUN_STARTED_EPOCH ]]; then
		duration=$((finished_epoch - RUN_STARTED_EPOCH))
	else
		duration=0
	fi
	{
		printf '%s\n' '-------------------------'
		printf 'finished_at: %s\n' "$finished_at"
		printf 'duration_seconds: %s\n' "$duration"
		printf 'status_code: %s\n' "$exit_code"
		printf '%s\n' '----- rnm log end -----'
	} >>"$LOG_FILE"
}

log_out() {
	local level="$1"
	local color="$2"
	shift 2

	if [[ $COLOR_STDOUT == true ]]; then
		printf '%s%s:%s %s\n' "$color" "$level" "$C_RESET" "$*"
	else
		printf '%s: %s\n' "$level" "$*"
	fi
	write_log_file "$level" "$*"
}

log_err() {
	local level="$1"
	local color="$2"
	shift 2

	if [[ $COLOR_STDERR == true ]]; then
		printf '%s%s:%s %s\n' "$color" "$level" "$E_RESET" "$*" >&2
	else
		printf '%s: %s\n' "$level" "$*" >&2
	fi
	write_log_file "$level" "$*"
}

log_info() {
	log_out "Info" "$C_INFO" "$*"
}

log_warn() {
	log_out "Skip" "$C_SKIP" "$*"
}

log_skip() {
	log_out "Skip" "$C_SKIP" "$*"
}

log_rename() {
	log_out "Rename" "$C_RENAME" "$*"
}

log_dry() {
	log_out "Dry-run" "$C_DRY" "$*"
}

log_error() {
	log_err "Error" "$E_ERROR" "$*"
}

on_err() {
	local -r exit_code="$1"
	local -r line_no="$2"
	local -r command_name="${3:-unknown}"
	log_error "Command failed (exit=$exit_code, line=$line_no): $command_name"
}

usage_die() {
	log_error "$@"
	exit 2
}

die() {
	log_error "$@"
	exit 1
}

get_script_path() {
	local script_dir script_name
	script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
	script_name="$(basename -- "${BASH_SOURCE[0]}")"
	printf '%s/%s\n' "$script_dir" "$script_name"
}

get_bundle_dir() {
	local script_dir env_dir
	script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
	if [[ -f $script_dir/man/rnm.1 || -d $script_dir/completions ]]; then
		printf '%s\n' "$script_dir"
		return 0
	fi
	env_dir="${RNM_SOURCE_DIR:-}"
	if [[ -n $env_dir && $env_dir == /* ]]; then
		env_dir="$(cd -- "$env_dir" && pwd -P)"
		if [[ -f $env_dir/man/rnm.1 || -d $env_dir/completions ]]; then
			printf '%s\n' "$env_dir"
			return 0
		fi
	fi
	printf '%s\n' "$script_dir"
}

require_install_cmd() {
	if ! command -v install >/dev/null 2>&1; then
		log_error 'install command not found.'
		exit 1
	fi
}

path_exists() {
	[[ -e $1 || -L $1 ]]
}

make_temp_file_in_dir() {
	local dir="$1"
	local template="$2"
	mktemp "$dir/$template"
}

require_absolute_base() {
	local name="$1"
	local value="$2"

	[[ $value == /* ]] || die "$name must be an absolute path: $value"
	[[ $value != *"/../"* && $value != */.. ]] || die "$name must not contain ..: $value"
}

get_xdg_config_home() {
	local base="${XDG_CONFIG_HOME:-$HOME/.config}"
	require_absolute_base "XDG_CONFIG_HOME" "$base"
	printf '%s\n' "$base"
}

get_xdg_data_home() {
	local base="${XDG_DATA_HOME:-$HOME/.local/share}"
	require_absolute_base "XDG_DATA_HOME" "$base"
	printf '%s\n' "$base"
}

get_xdg_state_home() {
	local base="${XDG_STATE_HOME:-$HOME/.local/state}"
	require_absolute_base "XDG_STATE_HOME" "$base"
	printf '%s\n' "$base"
}

get_home_dir() {
	require_absolute_base "HOME" "$HOME"
	printf '%s\n' "$HOME"
}

validate_install_bases() {
	require_absolute_base "HOME" "$HOME"
	require_absolute_base "XDG_CONFIG_HOME" "${XDG_CONFIG_HOME:-$HOME/.config}"
	require_absolute_base "XDG_DATA_HOME" "${XDG_DATA_HOME:-$HOME/.local/share}"
}

is_group_or_other_writable() {
	local mode
	mode="$(stat -c '%a' -- "$1" 2>/dev/null || stat -f '%Lp' -- "$1" 2>/dev/null || printf '')"
	[[ -n $mode && ${mode: -2:1} =~ [2367] || -n $mode && ${mode: -1:1} =~ [2367] ]]
}

is_group_or_other_accessible() {
	local mode
	mode="$(stat -c '%a' -- "$1" 2>/dev/null || stat -f '%Lp' -- "$1" 2>/dev/null || printf '')"
	[[ -n $mode && ${mode: -2:1} =~ [1-7] || -n $mode && ${mode: -1:1} =~ [1-7] ]]
}

ensure_owned_directory() {
	local label="$1"
	local path="$2"

	if path_exists "$path"; then
		if [[ -L $path ]]; then
			log_error "$(printf '%s path is a symlink: %q' "$label" "$path")"
			exit 1
		fi
		if [[ ! -d $path ]]; then
			log_error "$(printf '%s path is not a directory: %q' "$label" "$path")"
			exit 1
		fi
		if [[ ! -O $path ]]; then
			log_error "$(printf '%s directory is not owned by current user: %q' "$label" "$path")"
			exit 1
		fi
		if is_group_or_other_writable "$path"; then
			log_error "$(printf '%s directory is writable by group or others: %q' "$label" "$path")"
			exit 1
		fi
		return
	fi

	install -d -m 0755 -- "$path"
	if [[ -L $path || ! -d $path || ! -O $path ]]; then
		log_error "$(printf '%s directory is unsafe after creation: %q' "$label" "$path")"
		exit 1
	fi
	if is_group_or_other_writable "$path"; then
		log_error "$(printf '%s directory is writable by group or others: %q' "$label" "$path")"
		exit 1
	fi
}

ensure_private_directory() {
	local label="$1"
	local path="$2"

	if path_exists "$path"; then
		if [[ -L $path || ! -d $path || ! -O $path ]] || is_group_or_other_accessible "$path"; then
			log_error "$(printf '%s directory is unsafe: %q' "$label" "$path")"
			exit 1
		fi
		return
	fi

	install -d -m 0700 -- "$path"
	if [[ -L $path || ! -d $path || ! -O $path ]] || is_group_or_other_accessible "$path"; then
		log_error "$(printf '%s directory is unsafe after creation: %q' "$label" "$path")"
		exit 1
	fi
}

atomic_install_file() {
	local source="$1"
	local dest="$2"
	local mode="$3"
	local label="$4"
	local dest_dir dest_base tmpfile

	dest_dir="$(dirname -- "$dest")"
	dest_base="$(basename -- "$dest")"
	tmpfile="$(make_temp_file_in_dir "$dest_dir" ".$dest_base.XXXXXX")"
	if install -m "$mode" -- "$source" "$tmpfile" && mv -f -- "$tmpfile" "$dest"; then
		return 0
	fi
	rm -f "$tmpfile"
	log_error "$(printf 'Failed to install %s: %q' "$label" "$dest")"
	exit 1
}

get_config_path() {
	printf '%s\n' "$(get_xdg_config_home)/rnm/config"
}

get_bin_path() {
	printf '%s\n' "$(get_home_dir)/.local/bin/rnm"
}

get_man_install_path() {
	printf '%s\n' "$(get_xdg_data_home)/man/man1/rnm.1"
}

get_man_source_path() {
	local bundle_dir candidate
	bundle_dir="$(get_bundle_dir)"
	candidate="$bundle_dir/man/rnm.1"
	if [[ -f $candidate ]]; then
		printf '%s\n' "$candidate"
		return
	fi

	candidate="$bundle_dir/rnm.1"
	if [[ -f $candidate ]]; then
		printf '%s\n' "$candidate"
	fi
}

get_bash_completion_install_path() {
	printf '%s\n' "$(get_xdg_data_home)/bash-completion/completions/rnm"
}

get_fish_completion_install_path() {
	printf '%s\n' "$(get_xdg_data_home)/fish/vendor_completions.d/rnm.fish"
}

get_zsh_completion_install_path() {
	printf '%s\n' "$(get_xdg_data_home)/zsh/site-functions/_rnm"
}

get_nu_completion_install_path() {
	printf '%s\n' "$(get_xdg_config_home)/nushell/completions/rnm.nu"
}

get_bash_completion_source_path() {
	local bundle_dir candidate
	bundle_dir="$(get_bundle_dir)"
	candidate="$bundle_dir/completions/rnm.bash"
	if [[ -f $candidate ]]; then
		printf '%s\n' "$candidate"
	fi
}

get_fish_completion_source_path() {
	local bundle_dir candidate
	bundle_dir="$(get_bundle_dir)"
	candidate="$bundle_dir/completions/rnm.fish"
	if [[ -f $candidate ]]; then
		printf '%s\n' "$candidate"
	fi
}

get_zsh_completion_source_path() {
	local bundle_dir candidate
	bundle_dir="$(get_bundle_dir)"
	candidate="$bundle_dir/completions/_rnm"
	if [[ -f $candidate ]]; then
		printf '%s\n' "$candidate"
	fi
}

get_nu_completion_source_path() {
	local bundle_dir candidate
	bundle_dir="$(get_bundle_dir)"
	candidate="$bundle_dir/completions/rnm.nu"
	if [[ -f $candidate ]]; then
		printf '%s\n' "$candidate"
	fi
}

normalize_completion_value() {
	local value
	value="$(printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]')"
	case "$value" in
	bash | fish | zsh | nu | all | detect)
		printf '%s\n' "$value"
		;;
	*)
		return 1
		;;
	esac
}

set_install_completions() {
	local normalized
	normalized="$(normalize_completion_value "$1")" || usage_die "Invalid completion mode: $1. Valid: bash, fish, zsh, nu, all, detect"
	INSTALL_COMPLETIONS="$normalized"
	INSTALL_COMPLETIONS_FROM_CLI=1
}

completion_mode_selects() {
	local shell_name="$1"
	local binary_name="$2"

	case "$INSTALL_COMPLETIONS" in
	all)
		return 0
		;;
	detect)
		command -v "$binary_name" >/dev/null 2>&1
		;;
	"$shell_name")
		return 0
		;;
	*)
		return 1
		;;
	esac
}

normalize_case_value() {
	local value
	value="$(printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]')"
	case "$value" in
	default)
		printf '%s\n' "kebab-case"
		;;
	camel-case | pascal-case | snake-case | screaming-snake-case | kebab-case)
		printf '%s\n' "$value"
		;;
	*)
		return 1
		;;
	esac
}

set_case_style() {
	local normalized
	normalized="$(normalize_case_value "$1")" || usage_die "Invalid case option: $1"
	CASE_STYLE="$normalized"
	CASE_FROM_CLI=1
}

apply_case_from_config() {
	local normalized
	normalized="$(normalize_case_value "$1")" || {
		log_error "$(printf 'Invalid case setting in config: %q' "$1")"
		exit 1
	}
	if [[ $CASE_FROM_CLI -eq 0 ]]; then
		CASE_STYLE="$normalized"
	fi
}

to_lower() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

to_upper() {
	printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

capitalize_word() {
	local word first rest
	word="$(to_lower "$1")"
	first="${word:0:1}"
	rest="${word:1}"
	first="$(printf '%s' "$first" | tr '[:lower:]' '[:upper:]')"
	printf '%s%s' "$first" "$rest"
}

split_words() {
	local input spaced
	local -a words
	input="$1"
	spaced="$(printf '%s\n' "$input" | sed -E 's/([[:lower:][:digit:]])([[:upper:]])/\1 \2/g; s/([[:upper:]])([[:upper:]][[:lower:]])/\1 \2/g')"
	spaced="$(printf '%s\n' "$spaced" | tr -c '[:alnum:]\n' ' ')"
	read -r -a words <<<"$spaced"
	printf '%s\n' "${words[@]}"
}

format_case() {
	local input="$1"
	local -a words
	local output="" word

	mapfile -t words < <(split_words "$input")
	if [[ ${#words[@]} -eq 0 ]]; then
		printf '%s\n' ""
		return
	fi

	case "$CASE_STYLE" in
	kebab-case)
		for word in "${words[@]}"; do
			word="$(to_lower "$word")"
			if [[ -n $output ]]; then
				output+="-"
			fi
			output+="$word"
		done
		;;
	snake-case)
		for word in "${words[@]}"; do
			word="$(to_lower "$word")"
			if [[ -n $output ]]; then
				output+="_"
			fi
			output+="$word"
		done
		;;
	screaming-snake-case)
		for word in "${words[@]}"; do
			word="$(to_upper "$word")"
			if [[ -n $output ]]; then
				output+="_"
			fi
			output+="$word"
		done
		;;
	camel-case)
		output="$(to_lower "${words[0]}")"
		for word in "${words[@]:1}"; do
			output+="$(capitalize_word "$word")"
		done
		;;
	pascal-case)
		for word in "${words[@]}"; do
			output+="$(capitalize_word "$word")"
		done
		;;
	esac

	printf '%s\n' "$output"
}

normalize_extension() {
	local ext="$1"
	if [[ $CASE_STYLE == "screaming-snake-case" ]]; then
		printf '%s\n' "$(to_upper "$ext")"
	else
		printf '%s\n' "$(to_lower "$ext")"
	fi
}

is_regex_pattern() {
	[[ $1 == re:* || $1 == regex:* ]]
}

strip_regex_prefix() {
	local pattern="$1"
	pattern="${pattern#re:}"
	pattern="${pattern#regex:}"
	printf '%s\n' "$pattern"
}

validate_pattern() {
	local pattern="$1"
	if is_regex_pattern "$pattern"; then
		local regex
		regex="$(strip_regex_prefix "$pattern")"
		if [[ -z $regex ]]; then
			log_error 'Empty regex pattern in config.'
			exit 1
		fi
	fi
}

pattern_matches() {
	local rel_path="$1"
	local base="$2"
	local pattern="$3"

	if is_regex_pattern "$pattern"; then
		local regex
		regex="$(strip_regex_prefix "$pattern")"
		if [[ $rel_path =~ $regex || $base =~ $regex ]]; then
			return 0
		fi
		return 1
	fi

	# shellcheck disable=SC2254
	case "$rel_path" in
	$pattern | $pattern/* | */$pattern/*) return 0 ;;
	esac

	# shellcheck disable=SC2254
	case "$base" in
	$pattern) return 0 ;;
	esac

	return 1
}

validate_config_file() {
	local config_path="$1"

	if [[ -L $config_path ]]; then
		log_error "$(printf 'Config file is a symlink: %q' "$config_path")"
		exit 1
	fi

	if [[ ! -f $config_path ]]; then
		log_error "$(printf 'Config path is not a regular file: %q' "$config_path")"
		exit 1
	fi

	if [[ ! -r $config_path ]]; then
		log_error "$(printf 'Config file is not readable: %q' "$config_path")"
		exit 1
	fi

	if [[ ! -O $config_path ]]; then
		log_error "$(printf 'Config file is not owned by current user: %q' "$config_path")"
		exit 1
	fi

	if is_group_or_other_writable "$config_path"; then
		log_error "$(printf 'Config file is writable by group or others: %q' "$config_path")"
		exit 1
	fi
}

install_binary() {
	local mode="$1"
	local dest_dir dest_path script_path had_dest

	had_dest=0

	dest_path="$(get_bin_path)"
	dest_dir="$(dirname -- "$dest_path")"
	script_path="$(get_script_path)"

	if [[ ! -f $script_path ]]; then
		log_error 'Unable to resolve script path for install.'
		exit 1
	fi

	if [[ $script_path == "$dest_path" ]]; then
		log_warn "$(printf 'Already installed: %q' "$dest_path")"
		return
	fi

	if path_exists "$dest_path"; then
		had_dest=1
		if [[ -d $dest_path ]]; then
			log_error "$(printf 'Binary path is a directory: %q' "$dest_path")"
			exit 1
		fi
		if [[ -L $dest_path ]]; then
			log_error "$(printf 'Binary path is a symlink: %q' "$dest_path")"
			exit 1
		fi
		if [[ $mode == "install" ]]; then
			log_warn "$(printf 'Already installed: %q' "$dest_path")"
			return
		fi
	fi

	ensure_owned_directory "Binary" "$dest_dir"
	atomic_install_file "$script_path" "$dest_path" "0755" "Binary"
	if [[ $mode == "reinstall" && $had_dest -eq 1 ]]; then
		log_info "$(printf 'Reinstalled: %q' "$dest_path")"
	else
		log_info "$(printf 'Installed: %q' "$dest_path")"
	fi
}

install_man() {
	local mode="$1"
	local source dest_path dest_dir had_dest

	had_dest=0

	source="$(get_man_source_path)"
	if [[ -z $source ]]; then
		log_error 'Man page source not found.'
		exit 1
	fi
	if [[ -L $source ]]; then
		log_error "$(printf 'Man page source is a symlink: %q' "$source")"
		exit 1
	fi

	dest_path="$(get_man_install_path)"
	dest_dir="$(dirname -- "$dest_path")"

	if path_exists "$dest_path"; then
		had_dest=1
		if [[ -d $dest_path ]]; then
			log_error "$(printf 'Man page path is a directory: %q' "$dest_path")"
			exit 1
		fi
		if [[ -L $dest_path ]]; then
			log_error "$(printf 'Man page path is a symlink: %q' "$dest_path")"
			exit 1
		fi
		if [[ $mode == "install" ]]; then
			log_warn "$(printf 'Man page already installed: %q' "$dest_path")"
			return
		fi
	fi

	ensure_owned_directory "Man page" "$dest_dir"
	atomic_install_file "$source" "$dest_path" "0644" "Man page"
	if [[ $mode == "reinstall" && $had_dest -eq 1 ]]; then
		log_info "$(printf 'Man page reinstalled: %q' "$dest_path")"
	else
		log_info "$(printf 'Man page installed: %q' "$dest_path")"
	fi
}

install_completion_file() {
	local mode="$1"
	local label="$2"
	local source="$3"
	local dest="$4"
	local dest_dir had_dest

	if [[ -z $source || ! -f $source ]]; then
		log_error "$(printf '%s completion source not found.' "$label")"
		exit 1
	fi
	if [[ -L $source ]]; then
		log_error "$(printf '%s completion source is a symlink: %q' "$label" "$source")"
		exit 1
	fi

	dest_dir="$(dirname -- "$dest")"
	had_dest=0

	ensure_owned_directory "$label completion" "$dest_dir"

	if path_exists "$dest"; then
		had_dest=1
		if [[ -d $dest ]]; then
			log_error "$(printf '%s completion path is a directory: %q' "$label" "$dest")"
			exit 1
		fi
		if [[ -L $dest ]]; then
			log_error "$(printf '%s completion path is a symlink: %q' "$label" "$dest")"
			exit 1
		fi
		if [[ $mode == "install" ]]; then
			log_warn "$(printf '%s completion already installed: %q' "$label" "$dest")"
			return
		fi
	fi

	atomic_install_file "$source" "$dest" "0644" "$label completion"
	if [[ $mode == "reinstall" && $had_dest -eq 1 ]]; then
		log_info "$(printf '%s completion reinstalled: %q' "$label" "$dest")"
	else
		log_info "$(printf '%s completion installed: %q' "$label" "$dest")"
	fi
}

install_selected_completion() {
	local mode="$1"
	local shell_name="$2"
	local binary_name="$3"
	local label="$4"
	local source="$5"
	local dest="$6"

	if completion_mode_selects "$shell_name" "$binary_name"; then
		install_completion_file "$mode" "$label" "$source" "$dest"
	elif [[ $INSTALL_COMPLETIONS == "detect" ]]; then
		log_warn "$(printf '%s shell not detected; completion not installed.' "$label")"
	fi
}

install_completions() {
	local mode="$1"

	install_selected_completion "$mode" "bash" "bash" "Bash" "$(get_bash_completion_source_path)" "$(get_bash_completion_install_path)"
	install_selected_completion "$mode" "fish" "fish" "Fish" "$(get_fish_completion_source_path)" "$(get_fish_completion_install_path)"
	install_selected_completion "$mode" "zsh" "zsh" "Zsh" "$(get_zsh_completion_source_path)" "$(get_zsh_completion_install_path)"
	install_selected_completion "$mode" "nu" "nu" "Nu" "$(get_nu_completion_source_path)" "$(get_nu_completion_install_path)"
}

files_differ() {
	local source="$1"
	local dest="$2"

	[[ -f $dest ]] || return 0
	! cmp -s -- "$source" "$dest"
}

update_file_if_changed() {
	local label="$1"
	local source="$2"
	local dest="$3"
	local mode="$4"
	local dest_dir

	if [[ -z $source || ! -f $source ]]; then
		if path_exists "$dest"; then
			log_warn "$(printf '%s source not found; leaving installed file unchanged: %q' "$label" "$dest")"
			return
		fi
		log_error "$(printf '%s source not found.' "$label")"
		exit 1
	fi
	if [[ -L $source ]]; then
		log_error "$(printf '%s source is a symlink: %q' "$label" "$source")"
		exit 1
	fi

	dest_dir="$(dirname -- "$dest")"
	ensure_owned_directory "$label" "$dest_dir"

	if path_exists "$dest"; then
		if [[ -d $dest ]]; then
			log_error "$(printf '%s path is a directory: %q' "$label" "$dest")"
			exit 1
		fi
		if [[ -L $dest ]]; then
			log_error "$(printf '%s path is a symlink: %q' "$label" "$dest")"
			exit 1
		fi
		if ! files_differ "$source" "$dest"; then
			log_warn "$(printf '%s unchanged: %q' "$label" "$dest")"
			return
		fi
	fi

	atomic_install_file "$source" "$dest" "$mode" "$label"
	log_info "$(printf '%s updated: %q' "$label" "$dest")"
}

update_selected_completion() {
	local shell_name="$1"
	local binary_name="$2"
	local label="$3"
	local source="$4"
	local dest="$5"

	if completion_mode_selects "$shell_name" "$binary_name"; then
		update_file_if_changed "$label completion" "$source" "$dest" "0644"
	elif [[ $INSTALL_COMPLETIONS == "detect" ]]; then
		log_warn "$(printf '%s shell not detected; completion not updated.' "$label")"
	fi
}

update_completions() {
	update_selected_completion "bash" "bash" "Bash" "$(get_bash_completion_source_path)" "$(get_bash_completion_install_path)"
	update_selected_completion "fish" "fish" "Fish" "$(get_fish_completion_source_path)" "$(get_fish_completion_install_path)"
	update_selected_completion "zsh" "zsh" "Zsh" "$(get_zsh_completion_source_path)" "$(get_zsh_completion_install_path)"
	update_selected_completion "nu" "nu" "Nu" "$(get_nu_completion_source_path)" "$(get_nu_completion_install_path)"
}

install_self() {
	require_install_cmd
	install_binary "install"
	install_man "install"
	install_completions "install"
}

reinstall_self() {
	require_install_cmd
	install_binary "reinstall"
	install_man "reinstall"
	install_completions "reinstall"
}

update_self() {
	require_install_cmd
	update_file_if_changed "Binary" "$(get_script_path)" "$(get_bin_path)" "0755"
	update_file_if_changed "Man page" "$(get_man_source_path)" "$(get_man_install_path)" "0644"
	update_completions
}

uninstall_file() {
	local label="$1"
	local path="$2"

	if path_exists "$path"; then
		if [[ -L $path ]]; then
			log_error "$(printf '%s path is a symlink: %q' "$label" "$path")"
			exit 1
		fi
		if [[ -d $path ]]; then
			log_error "$(printf '%s path is a directory: %q' "$label" "$path")"
			exit 1
		fi
		rm -- "$path"
		log_info "$(printf '%s removed: %q' "$label" "$path")"
	else
		log_warn "$(printf '%s not installed: %q' "$label" "$path")"
	fi
}

uninstall_self() {
	uninstall_file "Binary" "$(get_bin_path)"
	uninstall_file "Man page" "$(get_man_install_path)"
	uninstall_file "Bash completion" "$(get_bash_completion_install_path)"
	uninstall_file "Fish completion" "$(get_fish_completion_install_path)"
	uninstall_file "Zsh completion" "$(get_zsh_completion_install_path)"
	uninstall_file "Nu completion" "$(get_nu_completion_install_path)"
}

remove_config() {
	local config_path

	config_path="$(get_config_path)"

	if path_exists "$config_path"; then
		if [[ -L $config_path ]]; then
			log_error "$(printf 'Config file is a symlink: %q' "$config_path")"
			exit 1
		fi
		if [[ -d $config_path ]]; then
			log_error "$(printf 'Config path is a directory: %q' "$config_path")"
			exit 1
		fi
		if [[ ! -O $config_path ]]; then
			log_error "$(printf 'Config file is not owned by current user: %q' "$config_path")"
			exit 1
		fi
		rm -- "$config_path"
		log_info "$(printf 'Config removed: %q' "$config_path")"
	else
		log_warn "$(printf 'Config not found: %q' "$config_path")"
	fi
}

purge_self() {
	uninstall_self
	remove_config
}

generate_config() {
	local config_path config_dir tmpfile

	require_install_cmd
	config_path="$(get_config_path)"
	config_dir="$(dirname -- "$config_path")"
	ensure_owned_directory "Config" "$config_dir"

	if path_exists "$config_path"; then
		if [[ -L $config_path ]]; then
			log_error "$(printf 'Config file is a symlink: %q' "$config_path")"
			exit 1
		fi
		log_warn "$(printf 'Config exists: %q' "$config_path")"
		return
	fi

	tmpfile="$(make_temp_file_in_dir "$config_dir" rnm.XXXXXX)"
	trap 'rm -f "$tmpfile"' RETURN
	printf 'case=default\ndisable-log=false\n[exclude]\n// list file(s)/folder(s) to exclude\n[include]\n// list file(s)/folder(s) to include\n' >"$tmpfile"
	if ln "$tmpfile" "$config_path" 2>/dev/null; then
		rm -f "$tmpfile"
		if [[ -f $config_path && ! -L $config_path ]]; then
			log_info "$(printf 'Config generated: %q' "$config_path")"
			return
		fi
	fi
	if path_exists "$config_path"; then
		if [[ -L $config_path ]]; then
			log_error "$(printf 'Config file is a symlink: %q' "$config_path")"
			exit 1
		fi
		log_warn "$(printf 'Config exists: %q' "$config_path")"
		return
	fi

	log_error "$(printf 'Failed to write config: %q' "$config_path")"
	exit 1
}

usage() {
	cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] TARGET_DIR

Recursively rename files and directories under TARGET_DIR.

Options:
  -d, --dry-run           Show renames without applying them
      --disable-log       Disable file logging
      --rollback          Execute the latest rollback script and remove it
      --install-completions MODE
                          Install/update completions for bash, fish, zsh, nu, all, or detect
  -c, --gen-config        Generate a default config file
  -i, --install           Install binary, man page, and detected completions
  -r, --reinstall         Reinstall binary, man page, and selected completions
  -u, --update            Update changed binary, man page, and selected completions
  -x, --uninstall         Remove binary, man page, and completions
  -p, --purge             Remove binary, man page, completions, and config
  -h, --help              Show this help message
EOF
}

show_help() {
	local man_path source_path data_home

	source_path="$(get_man_source_path)"
	if command -v man >/dev/null 2>&1 && [[ -n $source_path && -f $source_path ]]; then
		man -l -- "$source_path"
		return 0
	fi
	if command -v man >/dev/null 2>&1 && [[ ${HOME:-} == /* ]]; then
		data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
		if [[ $data_home == /* && $data_home != *"/../"* && $data_home != */.. ]]; then
			man_path="$data_home/man/man1/rnm.1"
			if [[ -f $man_path ]]; then
				man -l -- "$man_path"
				return 0
			fi
		fi
	fi
	usage
}

set_action() {
	local -r next="$1"
	if [[ -n $ACTION && $ACTION != "$next" ]]; then
		usage_die "Conflicting options: $ACTION and $next"
	fi
	ACTION="$next"
}

apply_bool_config() {
	local -r key="$1"
	local -r value="$2"
	local normalized
	normalized="$(printf '%s\n' "$value" | tr '[:upper:]' '[:lower:]')"
	case "$key=$normalized" in
	disable-log=true | disable-log=yes | disable-log=1) DISABLE_LOG=1 ;;
	disable-log=false | disable-log=no | disable-log=0) DISABLE_LOG=0 ;;
	*) die "Invalid config setting: $key=$value" ;;
	esac
}

load_rename_config() {
	local config_path current_section line

	config_path="$(get_config_path)"
	EXCLUDE_PATTERNS=(
		".git"
		"LICENSE*"
		"README*"
	)
	INCLUDE_PATTERNS=()

	if ! path_exists "$config_path"; then
		return 0
	fi

	validate_config_file "$config_path"
	current_section=""
	while IFS= read -r line || [[ -n $line ]]; do
		line="${line%%#*}"
		line="$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		[[ -z $line ]] && continue
		[[ ${line:0:2} == "//" ]] && continue

		if [[ -z $current_section && $line =~ ^case[[:space:]]*= ]]; then
			apply_case_from_config "$(printf '%s\n' "${line#*=}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
			continue
		fi

		if [[ $line == "[exclude]" ]]; then
			current_section="exclude"
			continue
		elif [[ $line == "[include]" ]]; then
			current_section="include"
			continue
		fi

		if [[ $current_section == "exclude" ]]; then
			validate_pattern "$line"
			EXCLUDE_PATTERNS+=("$line")
		elif [[ $current_section == "include" ]]; then
			validate_pattern "$line"
			INCLUDE_PATTERNS+=("$line")
		fi
	done <"$config_path"
}

should_ignore() {
	local path="$1"
	local base
	base=$(basename -- "$path")
	local rel_path="${path#"$TARGET_DIR"}"
	rel_path="${rel_path#/}"

	[[ -z $rel_path || $rel_path == "." || $rel_path == ".." ]] && return 0

	for pattern in "${EXCLUDE_PATTERNS[@]}"; do
		if pattern_matches "$rel_path" "$base" "$pattern"; then
			return 0
		fi
	done

	if [[ $base == .* ]]; then
		for pattern in "${INCLUDE_PATTERNS[@]}"; do
			if pattern_matches "$rel_path" "$base" "$pattern"; then
				return 1
			fi
		done
		return 0
	fi

	return 1
}

normalize() {
	format_case "$1"
}

record_rename() {
	local old_path="$1"
	local new_path="$2"
	RENAME_OLD_PATHS+=("$old_path")
	RENAME_NEW_PATHS+=("$new_path")
}

get_rollback_script_path() {
	printf '%s\n' "$(get_xdg_state_home)/rnm/rnm-rollback.sh"
}

validate_rollback_script() {
	local rollback_path="$1"

	if [[ -L $rollback_path ]]; then
		die "Rollback script is a symlink: $rollback_path"
	fi
	if [[ ! -f $rollback_path ]]; then
		die "Rollback script not found: $rollback_path"
	fi
	if [[ ! -O $rollback_path ]]; then
		die "Rollback script is not owned by current user: $rollback_path"
	fi
	if is_group_or_other_accessible "$rollback_path"; then
		die "Rollback script is accessible by group or others: $rollback_path"
	fi
}

write_rollback_script() {
	local state_dir rollback_path tmpfile index source target quoted_source quoted_target

	[[ $DRY_RUN -eq 0 && ${#RENAME_OLD_PATHS[@]} -gt 0 ]] || return 0
	state_dir="$(get_xdg_state_home)/rnm"
	ensure_private_directory "State" "$state_dir"
	rollback_path="$(get_rollback_script_path)"
	if path_exists "$rollback_path"; then
		if [[ -L $rollback_path || -d $rollback_path || ! -O $rollback_path ]] || is_group_or_other_accessible "$rollback_path"; then
			die "Rollback script path is unsafe: $rollback_path"
		fi
	fi
	tmpfile="$(make_temp_file_in_dir "$state_dir" ".rnm-rollback.XXXXXX")"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'set -Eeuo pipefail'
		printf '%s\n' ''
		printf '%s\n' '# Generated by rnm. Executes the latest rollback only.'
		for ((index = ${#RENAME_OLD_PATHS[@]} - 1; index >= 0; index--)); do
			source="${RENAME_NEW_PATHS[$index]}"
			target="${RENAME_OLD_PATHS[$index]}"
			printf -v quoted_source '%q' "$source"
			printf -v quoted_target '%q' "$target"
			printf '[[ -e %s || -L %s ]] || { printf \"Rollback source missing: %%s\\n\" %s >&2; exit 1; }\n' "$quoted_source" "$quoted_source" "$quoted_source"
			printf '[[ ! -e %s && ! -L %s ]] || { printf \"Rollback target exists: %%s\\n\" %s >&2; exit 1; }\n' "$quoted_target" "$quoted_target" "$quoted_target"
			printf 'mv %s %s\n' "$quoted_source" "$quoted_target"
		done
	} >"$tmpfile"
	chmod 0700 "$tmpfile"
	if mv -f "$tmpfile" "$rollback_path"; then
		ROLLBACK_SCRIPT="$rollback_path"
		log_info "Rollback script: $ROLLBACK_SCRIPT"
		return 0
	fi
	rm -f "$tmpfile"
	die "Failed to write rollback script: $rollback_path"
}

run_rollback() {
	local rollback_path state_dir

	if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
		die "Do not run rollback operations as root."
	fi
	state_dir="$(get_xdg_state_home)/rnm"
	ensure_private_directory "State" "$state_dir"
	rollback_path="$(get_rollback_script_path)"
	validate_rollback_script "$rollback_path"
	bash "$rollback_path"
	rm "$rollback_path"
	log_info "Rollback completed: $rollback_path"
}

rename_item() {
	local path="$1"
	if should_ignore "$path"; then
		return
	fi

	local dir base name ext newname newpath
	dir=$(dirname -- "$path")
	base=$(basename -- "$path")

	if [[ -d $path ]]; then
		newname=$(normalize "$base")
	else
		if [[ $base == *.* ]]; then
			name="${base%.*}"
			ext="${base##*.}"
			name=$(normalize "$name")
			ext=$(normalize_extension "$ext")
			newname="$name.$ext"
		else
			newname=$(normalize "$base")
		fi
	fi

	newpath="$dir/$newname"

	[[ $path == "$newpath" ]] && return

	if [[ -z $newname || $newname == "." || $newname == ".." ]]; then
		log_skip "Invalid target name: $path -> $newpath"
		return
	fi

	if path_exists "$newpath"; then
		log_skip "Target exists: $path -> $newpath"
		return
	fi

	if [[ $DRY_RUN -eq 1 ]]; then
		log_dry "$path -> $newpath"
		return
	fi

	if mv -n "$path" "$newpath"; then
		if ! path_exists "$path" && path_exists "$newpath"; then
			record_rename "$path" "$newpath"
			log_rename "$path -> $newpath"
			return
		fi
		if path_exists "$newpath"; then
			log_skip "Target exists: $path -> $newpath"
			return
		fi
	fi

	if path_exists "$newpath"; then
		log_skip "Target exists: $path -> $newpath"
		return
	fi

	die "Failed to rename: $path -> $newpath"
}

run_rename() {
	if [[ ${#REQUESTED_PATHS[@]} -eq 0 ]]; then
		show_help
		exit 1
	fi

	if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
		die "Do not run rename operations as root."
	fi

	if [[ ${#REQUESTED_PATHS[@]} -gt 1 ]]; then
		usage_die "Only one TARGET_DIR is supported: ${REQUESTED_PATHS[1]}"
	fi

	TARGET_DIR="${REQUESTED_PATHS[0]}"

	if [[ ! -d $TARGET_DIR ]]; then
		die "$TARGET_DIR is not a directory."
	fi
	TARGET_DIR="$(cd -- "$TARGET_DIR" && pwd -P)"

	load_rename_config

	while IFS= read -r -d '' item; do
		rename_item "$item"
	done < <(find "$TARGET_DIR" -depth -print0)
	write_rollback_script
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-d | --dry-run) DRY_RUN=1 ;;
		--disable-log)
			DISABLE_LOG=1
			DISABLE_LOG_FROM_CLI=1
			;;
		--rollback) set_action rollback ;;
		--camel-case) set_case_style "camel-case" ;;
		--pascal-case) set_case_style "pascal-case" ;;
		--snake-case) set_case_style "snake-case" ;;
		--screaming-snake-case) set_case_style "screaming-snake-case" ;;
		--kebab-case) set_case_style "kebab-case" ;;
		-c | --gen-config) set_action gen-config ;;
		--install-completions=*) set_install_completions "${1#*=}" ;;
		--install-completions)
			shift
			[[ $# -gt 0 ]] || usage_die "Missing value for --install-completions."
			set_install_completions "$1"
			;;
		-i | --install) set_action install ;;
		-r | --reinstall) set_action reinstall ;;
		-u | --update) set_action update ;;
		-x | --uninstall) set_action uninstall ;;
		-p | --purge) set_action purge ;;
		-h | --help) set_action help ;;
		--)
			shift
			while [[ $# -gt 0 ]]; do
				REQUESTED_PATHS+=("$1")
				shift
			done
			break
			;;
		-*) usage_die "Unknown option: $1" ;;
		*)
			if [[ -n $ACTION && $ACTION != help ]]; then
				usage_die "Unexpected operand for --$ACTION: $1"
			fi
			REQUESTED_PATHS+=("$1")
			;;
		esac
		shift
	done
}

preload_disable_log_config() {
	local config_path line key value

	[[ $DISABLE_LOG_FROM_CLI -eq 0 ]] || return 0
	config_path="$(get_config_path)"
	[[ -r $config_path && ! -L $config_path && -f $config_path && -O $config_path ]] || return 0
	! is_group_or_other_writable "$config_path" || return 0
	while IFS= read -r line || [[ -n $line ]]; do
		line="${line%%#*}"
		line="$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		[[ -z $line || ${line:0:2} == "//" || $line != *=* ]] && continue
		key="$(printf '%s\n' "${line%%=*}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		value="$(printf '%s\n' "${line#*=}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		if [[ $key == "disable-log" ]]; then
			apply_bool_config "$key" "$value"
			return 0
		fi
	done <"$config_path"
}

main() {
	init_colors
	RUN_COMMAND="$(format_command "$0" "$@")"
	parse_args "$@"
	if [[ $ACTION != "help" ]]; then
		preload_disable_log_config
	fi
	init_logging
	write_log_header
	trap 'write_log_footer "$?"' EXIT
	trap 'on_err "$?" "${LINENO}" "${BASH_COMMAND}"' ERR

	if [[ $ACTION == "help" ]]; then
		show_help
		exit $?
	fi

	if [[ -z $ACTION && $INSTALL_COMPLETIONS_FROM_CLI -eq 1 ]]; then
		validate_install_bases
		if [[ ${#REQUESTED_PATHS[@]} -gt 0 ]]; then
			usage_die "Unexpected operand for --install-completions: ${REQUESTED_PATHS[0]}"
		fi
		require_install_cmd
		install_completions install
		exit 0
	fi

	if [[ -n $ACTION ]]; then
		validate_install_bases
		if [[ ${#REQUESTED_PATHS[@]} -gt 0 ]]; then
			usage_die "Unexpected operand for --$ACTION: ${REQUESTED_PATHS[0]}"
		fi
		case "$ACTION" in
		install) install_self ;;
		reinstall) reinstall_self ;;
		update) update_self ;;
		uninstall) uninstall_self ;;
		purge) purge_self ;;
		gen-config) generate_config ;;
		rollback) run_rollback ;;
		*) die "Internal error: unsupported action '$ACTION'" ;;
		esac
		exit 0
	fi

	run_rename
}

main "$@"
