#!/bin/sh
_tags=""
_sens=""
_relink=
_rsync=t
_archive=t
_dry_run=
_force=
_yes=
_merge_a=
_merge_b=
_use_meld="$(meld --version 2> /dev/null)"

HOSTNAME=$(hostname)
CONFIG_FILE=
DIFF_EXCLUDES="*.pyc,__pycache__,${DIFF_EXCLUDES}"
_diff_rq(){
  diff $(echo "${DIFF_EXCLUDES}" | sed 's/,$//;s/\(^\|,\)/ -x /g') -rq "${1}" "${2}"
}
usage () {
    cat <<EOUSE
Config files (load only one ordered by priority):
  \${CONFIG_PATH}/directories.\${HOSTNAME}
  \${CONFIG_PATH}/directories
  ~/.config/do_backup/directories.\${HOSTNAME}
  ~/.config/do_backup/directories

Config file format:
  #set local-remote synchronisation
  [rsync]
  /local/dir,  dir
  /local/dirb, dirb

  #use tags to categorise sections
  [rsync] EVERYDAY FAST CONFIG
  /local/dirc, dirc

  #just archive
  [archive]
  /local/dir, \$TARGET/dir.zip

  #rebuild links
  [link]
  ~/.dir, /local/dir

  #extends
  Include ./directories.*

Description:
  Perform a backup according to a config file
  containing csv lines organized by sections.
  These sections are related to the needed operation
  (rsync, archive, link).
  If no TARGET (remote) directory is specified,
  then the first encrypted USB key found is used.

Usage: $(basename $0) [TAG*] OPTIONS

Options:
    -t REMOTE_DIR     -- The backup dir (default: <chosen disk>/.backup)
    -c CONFIG_FILE    -- A custom config file
    --dry-run         -- Dry run : no effect
    --yes             -- Don't ask questions

  related to [rsync] sections:
    -b|-backup        -- Backup  (local  -> remote)
    -r|-restore       -- Restore (remote -> local )

  related to [archive] sections:
    -a|--archive      -- Perform archiving part (no sync)
    -noa|--no-archive -- Disable archiving

  related to [link] sections:
    -rl|--relink     -- Import links (no sync)

For cases you'll need to merge file by file, use (currently use meld):
  -m|--merge FOLDER_A FOLDER_B

EOUSE
}

# PARSING OPTIONS
_all_opts="$@"
while [ -n "$1" ]
do
  case ${1} in
    -b|-backup)
      _sens='backup'
      _relink=
      _archive=t
      ;;
    -r|-restore)
      _sens='restore'
      _relink=t
      _archive=
      ;;
    -m|--merge)
      _merge_a="$2"
      _merge_b="$3"
      shift 2
      ;;
    -f|--force)
      _force=t
      ;;
    -noa*|--no-a*)
      _archive=
      ;;
    -a*|--ar*)
      _archive=t
      _rsync=
      ;;
    -rl|--relink)
      _relink=t
      _rsync=
      _archive=
      ;;
    -t)
      TARGET="${2}"
      shift
      ;;
    -c)
      CONFIG_FILE="${2}"
      shift
      ;;
    --dry-run)
      _dry_run=t
      ;;
    -y*|--yes)
      _yes=t
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option : $1"
      exit 1
      ;;
    *)
      _tags="${_tags} ${1}"
      ;;
  esac
  shift
done

# Fetch config
for _dir in ${CONFIG_PATH} ${HOME}/.config/do_backup; do
   for _f in /directories; do
     for _variant in ".${HOSTNAME}" ""; do
      if [ -f "${_dir}${_f}${_variant}" ]; then
        CONFIG_FILE="${_dir}${_f}${_variant}"
        break
      fi
    done
  done
done
[ ! -f "${CONFIG_FILE}" ] && echo "Configuration file is required." && exit 1

_ask_yes_no_extended(){
  local title="$1"
  local choices descs i add_choice desc

  case "${_default_rep:-y}" in
    y)
      choices="Y/n"
      descs="Yes by default; no to skip;"
    ;;
    n)
      choices="y/N"
      descs="yes to confirm; No by default;"
    ;;
    *)
      choices="y/n"
      descs="yes to confirm; no to skip;"
    ;;
  esac
  shift
  for i in $*; do
    add_choice=true
    desc=
    case $i in
      d)
        desc="to diff"
        ;;
      r)
        desc="to switch source and target"
        ;;
      m)
        desc="to use meld"
        [ -z "${_use_meld}" ] && add_choice=false
        ;;
    esac
    if ${add_choice}; then
      if [ "${desc}" ]; then
        descs="${descs}$i "
        [ "${_default_rep}" = "$i" ] && descs="${descs}-by default- "
        descs="${descs}${desc}"
        descs="${descs};"
      fi
      [ "${_default_rep}" = "$i" ] && i=$(echo $i | tr [:lower:] [:upper:])
      choices="${choices}/$i"
    fi
  done
  echo "> ${title} [${choices}] ? (${descs})"
}

_ensure_dir_access(){
  [ ! -d "${1}" ]  && "ERROR: Can't acces to $1." && exit 2
}

_ensure_permissions(){
  if [ "`whoami`" != "root" ]; then
    if [ "${_merge_a}" ]; then
      TARGET="${_merge_a}"
      _ensure_dir_access "${_merge_a}" 
      _ensure_dir_access "${_merge_b}" 
    else
      [ "${TARGET}" ] && mkdir -p ${TARGET} > /dev/null
      if [ -z "${TARGET}" -o ! -d "${TARGET}" -o ! -w "${TARGET}" ]; then
         echo "(superuser access is needed to launch this script)" 
         sudo \
           TARGET=${TARGET} \
           HOME=${HOME} \
           sh -- $0 $_all_opts -c "${CONFIG_FILE}"
         exit $?
      fi
    fi
  fi

}

_ensure_target(){
  local i _devlist _dev _luksdev
  if [ -z "${TARGET:-}" ]
  then
    _devlist=
    for i in /dev/sd[bcdefg][123456]
    do
      test -e $i || continue
      if udisksctl info -b $i | grep crypto_ > /dev/null
      then
        _devlist="$_devlist $i $(udisksctl info -b $i | awk '/Symlinks:/ {print $2}')"
      fi
    done
    _lucksdev="$(whiptail --menu "Device ?" 0 0 0 ${_devlist} 3>&1 1>&2 2>&3)"

    if [ -z "$_lucksdev" ]; then echo "No luks dev found"; exit 1; fi
    echo "Using crypto device : ${_lucksdev}"


    _dev=$(udisksctl unlock -b $_lucksdev 2>&1 | sed -n 's|.*as [^/]*\(/[-a-zA-Z0-9/]\+\)[^-a-zA-Z0-9/]*.*|\1|p')
    TARGET=$(udisksctl mount -b $_dev 2>&1 | sed -n 's|.* at [^/]*\(/[-a-zA-Z0-9/]\+\)[^-a-zA-Z0-9/]*.*|\1|p')

    echo "${_lucksdev} -> ${_dev} -> ${TARGET}"

    umount_dev(){
      udisksctl unmount -b ${_dev}
      _ask_yes_no_extended "eject device"
      read ret
      if [ "${ret}" != "n" ]; then
        udisksctl lock -b ${_lucksdev}
        udisksctl power-off -b ${_lucksdev}
      fi
      exit 1
    }
    trap umount_dev 1 2 3 6 9
    [ -z "${TARGET}" -o ! -d "${TARGET}" ] && umount_dev && exit 1
    TARGET="$TARGET/.backup"
  fi
  mkdir -p $TARGET
  export TARGET
}

_confirm_sens(){
  if [ -n "${_sens}" ]
  then
    case ${_sens} in
      'backup')
        echo "All data from # local directory # will overwrite those in # ${TARGET} # (type 'yes' to confirm)"
        ;;
      'restore')
        echo "All data from # ${TARGET} # will overwrite those in  # local directory # (type 'yes' to confirm)"
        ;;
      *)
        echo "bug }8{"
        exit 1
        ;;
    esac 
    if [ -z "${_yes}" ]; then
    rep=""; read rep; if [ "${rep}" != "yes" ]
    then
      echo "Aborting"
      exit 1
    fi
    fi
  fi
}

_run(){
  if [ "${_dry_run}" ]; then
    echo "+ $@"
  else
    $@
  fi
}

check_filesystems(){
  local _fs_local _fs_remote
  [ -d "$1" ] && _d_local="$1" || _d_local="`dirname $1`"
  [ -d "$2" ] && _d_remote="$2" || _d_remote="`dirname $2`"
  _fs_local="`stat -f -c %T ${_d_local} | sed 's|ext.*|ext|;s|msdos.*|msdos|'`"
  _fs_remote="`stat -f -c %T ${_d_remote} | sed 's|ext.*|ext|;s|msdos.*|msdos|'`"
  if  [ "${_fs_local}" = "${_fs_remote}" ]
  then
    # _sync_method="rsync --progress -aH --delete --log-file=/tmp/rsync.`date '+%Y%m%d_%H%M%S'`.log --inplace"
    _sync_method="rsync -aHAX --delete --quiet --debug=none --msgs2stderr --inplace"
    return 0 
  elif  [ "${_fs_local}" = "msdos" ]
  then
    echo ": Warning : rights will not be preserved on msdos filesystem"
    _sync_method="cp -ruT"
    return 0 
  else
    echo ": syncing <${_fs_local}> and <${_fs_remote}> filesystems is forbidden"
    return 1
  fi
  echo
}

check_consistancy(){
  local ret _dates_a _dates_b _cur_a _cur_b _missing_a _missing_a
  if [ ! -f "${2}" ]
  then
    # either f1 exist or not
    ret=2
  elif [ ! -f "${1}" ]
  then
    # f1 not exist but f2 exist
    ret=3
  elif [ -f "${1}" -a -f "${2}" ]
  then
    ret=0
    # compare dates registered in touch_files
    _dates_a="$(grep '|' ${1} | cut -d'|' -f2 | sort -r | tr '\n' ' ')"
    _dates_b="$(grep '|' ${2} | cut -d'|' -f2 | sort -r | tr '\n' ' ')"
    if [ -n "${_dates_a}" -a -n "${_dates_b}" ]
    then 
      _cur_a="`echo ${_dates_a} | cut -d' ' -f1`"
      _cur_b="`echo ${_dates_b} | cut -d' ' -f1`"
      _missing_a=""
      _missing_b=""
      if [ ${_cur_a} -ne ${_cur_b} ] ; then 
        if [ ${_cur_a} -gt ${_cur_b} ]; then
          ret=4; _missing_b=${_cur_b}
        else
          ret=1; _missing_a="${_cur_a}"
        fi
        while [ -n "${_missing_a}" -a -n "${_dates_b}" ]; do
          _cur_b="`echo ${_dates_b} | cut -d' ' -f1`"
          _dates_b="`echo \"${_dates_b}\" | cut -d' ' -f2-`"
          if [ ${_cur_b} -eq ${_missing_a} ]; then break
          elif [ ${_cur_b} -gt ${_missing_a} ]; then continue
          else ret=99; break
          fi
        done
        while [ -n "${_missing_b}" -a -n "${_dates_a}" ]; do
          _cur_a="`echo ${_dates_a} | cut -d' ' -f1`"
          _dates_a="`echo \"${_dates_a}\" | cut -d' ' -f2-`"
          if [ ${_cur_a} -eq ${_missing_b} ];then break
          elif [ ${_cur_a} -gt ${_missing_b} ];then continue
          else ret=99; break
          fi
        done
      fi
    fi
  fi 
  if [ $ret -eq 99 -a -z "${_yes}" ]
  then
    echo
    echo "#! Inconsistancy detected .. you can try to repair it manually"
    sleep 1
    vimdiff ${1} ${2}
    _ask_yes_no_extended "Retry"
    rep=""; read rep; if [ -z "${rep}" -o "${rep}" = "yes" ]
    then
      check_consistancy $1 $2
      return $?
    fi
  fi
  return $ret
}

rsync_touch(){
  local _localdir=$1
  local _remotedir=$2
  local _reuse_touch=""
  local _noconfirm=""
  local _pass=""
  check_consistancy "${_localdir}/.backup_touch" "${_remotedir}/.backup_touch"
  local _consistancy=$?
  local _from _to
  if [ ${_consistancy} -lt 10  ]; then
    if [ "$(( _consistancy % 2 ))" -eq 0 ]; then
      _from="${_localdir}"
      _to="${_remotedir}"
      _computed_sens="backup"
      printf "\rRSYNC ${_from} => ${_to}"
    else
      _from="${_remotedir}"
      _to="${_localdir}"
      _computed_sens="restore"
      printf "\rRSYNC ${_to} <= ${_from}"
    fi
    if [ "${_sens}" ]; then  # sens choice is manual
      if [ "${_force}" -o "${_sens}" = "${_computed_sens}" ]; then
        _noconfirm="1"
      else
        _pass="1"
      fi
    fi
    [ "${_pass}" ] && echo ": SKIP" || echo
    case ${_consistancy} in
      0)
        echo "#! Version equals : new version will be created"
        ;;
      1)
        echo "#! Remote version is newer than local"
        _reuse_touch="true"
        ;;
      2)
        echo "#! No version registered : sync on local version (new)"
        ;;
      3)
        echo "#! Local directory is not versionned : sync on remote version"
        _reuse_touch="true"
        if [ -d ${_to} ]
        then
          rep=""
          if [ -z "${_yes}" ]
          then
            echo "#! It look like your local version is obsolete."
            _ask_yes_no_extended "Do you want to move it before overiding data"
            read  rep
          else
            echo "#! backuping obsolete directory"
          fi
          if [ -z "${rep}" -o "${rep}" = "yes" ]
          then
            echo "#! Moving files to ${to}_bak"
            _run mv "${_to}" "${_to}_bak"
          fi 
        fi
        ;;
      4)
        echo "#! Local version is newer than remote "
        _reuse_touch="true"
        ;;
    esac
    # echo "# From        : ${_from}"
    # echo "# To          : ${_to}"
    rep=""
    if [ -n "${_pass}" ]
    then
      rep="n"
    else
      if [ -z "${_yes}${_noconfirm}" ]
      then
        if [ ${_to}/.backup_touch -nt ${_from}/.backup_touch ]
        then 
          echo  "Warning : backup report of the target is newer than source"
        fi
        _ask_yes_no_extended "Rsync" d m r
        read  rep
        if [ "${rep}" = "d" ]
        then
          tmpfile="`mktemp`"
          LANG='EN' _diff_rq ${_from} ${_to} > ${tmpfile}
          if [ $? -eq 0 ]
          then
            echo "Skip because source and target equal."
            rm ${tmpfile}
            return 1
          fi
          tmpfileb="`mktemp`"
          sleep 1
          while read i
          do
            echo "#- $i"
            case "$i" in
              "Only"*)  # diff message "Only in "
                continue
                ;;
            esac
            tmp="`echo \"$i\" | sed 's/Files \([^ ]*\) and \([^ ]*\) differ/\1\|\2/'`"
            tmpa="`echo $tmp | cut -d '|' -f1`"
            tmpb="`echo $tmp | cut -d '|' -f2`"
            if [ ${tmpa} -ot ${tmpb} ]
            then
              echo "--> /!\\ source is older then target."
            else
              echo "--> diff [  <:source |  >:current target  ]"
              diff ${tmpa} ${tmpb}
            fi
            echo
          done < ${tmpfile} > ${tmpfileb}
          more ${tmpfileb}
          rm ${tmpfile} ${tmpfileb}
          echo 
          echo "- Last modification for source/.backup_touch : `stat -c '%y' ${_from}/.backup_touch`"
          echo "- Last modification for target/.backup_touch : `stat -c '%y' ${_to}/.backup_touch`"
          echo "# From        : ${_from}"
          echo "# To          : ${_to}"
          _ask_yes_no_extended "Rsync" m r
          read  rep
        fi
        if [ "${rep}" = "m" ]
        then
          meld ${_from} ${_to}
          _ask_yes_no_extended "Rsync" r
        fi
        if [ "${rep}" = "r" ]
        then
          _tmp="${_from}"
          _from="${_to}"
          _to="${_tmp}"
          echo "# From        : ${_from}"
          echo "# To          : ${_to}"
          _ask_yes_no_extended "Rsync" 
          read  rep
        fi
      fi
    fi
    _from_TOUCH="${_from}/.backup_touch"
    _to_TOUCH="${_to}/.backup_touch"
    if [ -z "${rep}" -o "${rep}" = "yes" -o  "${rep}" = "y" ]
    then
      if [ -n "${_reuse_touch}" -a -z "${_dry_run}" ]
      then
        sed -i "\$s#\$#|re-used:$(date '+%Y/%m/%d %H:%M:%S')#" "${_from_TOUCH}"
      fi

      _run ${_sync_method} ${_from}/ ${_to} 2> /dev/null

      if [ -z "${_reuse_touch}${_dry_run}" ]
      then
        date '+%Y/%m/%d %H:%M:%S|%s' | tee -a "${_from_TOUCH}" "${_to_TOUCH}" > /dev/null
      fi
    else
      echo "#! Skip as you said ${rep}"
    fi
  else
    echo "#! Inconsistancy detected : skip"
  fi
  if [ -f "${_from}/.backup_touch" ]; then
    _uid_from=$(stat -c "%U" ${_from})
    chown ${_uid_from} "${_from}/.backup_touch"
  fi
  if [ -f "${_to}/.backup_touch" ]; then
    _uid_to=$(stat -c "%U" ${_to})
    chown ${_uid_to} "${_to}/.backup_touch"
  fi
}

try_to_link(){
  f_link="${1}"
  f_file="${2}"
  rep=""
  if [ ! -e "${f_file}" ]; then 
    echo ": file (2) not exists"
    if [ -e "${f_link}" -a ! -L "${f_link}" ]
    then
      echo "/ The target is a concrete file or directory and the source does not exist."
      _default_rep=n _ask_yes_no_extended "Setup the link (move files and create the link)"
      [ -z "${_yes}" ] && read rep || rep = "y"
      if [ "${rep}" = "y" ] 
      then
        _run mv "${f_link}" "${f_file}" && echo "files moved"
        _run ln -s "${f_file}" "${f_link}" && echo "link created : ok"
      else
        echo "pass"
      fi
    else
      echo "/ failure" 
    fi
  elif [ -L "${f_link}" ]; then 
    if [ "${f_file}" = "`readlink ${f_link}`" ]
    then
      echo ": OK"
    else
      echo ": (1) already exists"

      if [ -z "${_yes}" ]; then
        _ask_yes_no_extended "(break link with `readlink ${f_link}`)"
        read rep
      fi
      if [ "${rep}" = "n" ]; then
        echo "pass"
      else
        _run unlink "${f_link}"
        _run ln -s "${f_file}" "${f_link}"
        echo "Overwrite ${f_link}"
      fi
    fi
  elif [ -e "${f_link}" ]; then
    echo ": (1) is a concrete file or directory"
    if [ -n "${SHELL}" ]; then
      _default_rep=n _ask_yes_no_extended "Do you want to resolve the conflict"
      [ -z "${_yes}" ] && read rep || rep = "n"
      if [ "${rep}" = "y" ] 
      then
        echo "/ Here the commands you need :"
        echo "ls ${f_link}"
        echo "diff ${f_link} ${f_file}"
        echo "mv ${f_link}/* ${f_file}/"
        echo "rm -rf ${f_link}"
        echo "type 'exit 0' to leave shell and retry"
        echo "## LINK RESOLUTION MODE ${SHELL} ##############"
        ${SHELL} && echo "###BACK TO $0 ############" && try_to_link ${f_link} ${f_file} 
      fi
    else
      echo "pass"
    fi
  else
    _run ln -s "${f_file}" "${f_link}" && echo ": link creation ok"
  fi
}

_process_line(){
  value1="$(eval "echo \"${2}\"")"
  value2="$(eval "echo \"${3}\"")"
  case "$1" in
    archive)
      [ -z "${_archive}" ] && return
      _add_b_in_a=t
      case "${value2}" in
        *.zip)
          _cmd="zip -r"
          ;;
        *.tgz|*.tar.gz)
          _cmd="tar -czf"
          ;;
        *.tar)
          _cmd="tar -cf"
          ;;
        *.7z)
          _cmd="7z a"
          ;;
        *.rar)
          _cmd="rar a"
          ;;
        *)
          if [ -f "${value1}" -a -d "${value2}" ]; then
            _cmd="cp -p"
          else
            _cmd="cp -rpT"
          fi
          _add_b_in_a=
          ;;
      esac
      echo "ARCHIVE ${value1} IN ${value2}"
      if [ "${_add_b_in_a}" ]; then
        _run ${_cmd} ${value2} ${value1}
      else
        _run ${_cmd} ${value1} ${value2}
      fi
      ;;
    link)
      [ -z "${_relink}" ] && return
      printf "LINK $value1 -> $value2"
      try_to_link $value1 $value2
      ;;
    fetch)
      [ -z "${_rsync}" ] && return
      [ "${_sens}" = "backup" ] && return
      _local="$value1"
      _remote="$TARGET/$value2"
      if check_filesystems ${_local} ${_remote}
      then
        printf "\rFetch ${_remote} => ${_local}\n"
        rep=y
        if [ -z "${_yes}" ]
        then
          _ask_yes_no_extended "Fetch content and override existing"
          read  rep
        fi
        if [ "${rep}" = "n" ]; then
          echo "pass"
        else
          _run ${_sync_method} ${_remote}/ ${_local} 2> /dev/null
        fi
      fi
      ;;
    meld)
      _local="$value1"
      _remote="$TARGET/$value2"
      if check_filesystems ${_local} ${_remote}
      then
        printf "\rOpenning meld on  ${_remote} <> ${_local}\n"
        meld ${_local} ${_remote} 
      fi
      ;;
    rsync)
      [ -z "${_rsync}" ] && return
      _local="$value1"
      _remote="$TARGET/$value2"
      printf "RSYNC ${_local} -> ${_remote} "
      if check_filesystems ${_local} ${_remote}
      then
        if [ -d ${_local} ]
        then
          rsync_touch ${_local} ${_remote}
        else
          _diff=
          _new_r=
          if [ -f "${_remote}" -a -f "${_local}" ]; then
            if  [ "$(sum "${_remote}")" != "$(sum "${_local}")" ]; then
              _diff="t"
              if [ "${_remote}" -nt "${_local}" ]; then
                _new_r="t"
                printf ": remote newer than local"
              else
                printf ": local newer than remote"
              fi
            fi
          fi
          if [ -f "${_remote}" ]; then
            if [ "${_sens}" ] ;then
              if [ "${_sens}" = "restore" ]; then
                 [ "${_force}" -o "${_new_r}" -o ! -f "${_local}" ] && _run cp -pT ${_remote} ${_local}
              elif [ "${_sens}" = "backup" ]; then
                 [ "${_force}" -o -z "${new_r}" ] && _run cp -pT ${_local} ${_remote}
              fi
            else
              if [ "${_new_r}" -o ! -f "${_local}" ]; then
                  _run cp -pT ${_remote} ${_local}
              elif [ "${_diff}" ]; then
                  _run cp -pT ${_local} ${_local}
              fi
            fi
          elif [ -f "${_local}" ]; then
            _run cp -pT ${_local} ${_remote}
          fi
          echo
        fi
      fi
      ;;
  esac
}

_read_cfg(){
    echo "… using config $1\n"
    i=0
    _maxlen=$(wc -l ${1} | awk '{print $1}')
    while [ $i -lt $_maxlen ]; do
      i=$((i+1))
      l="$(sed -n "${i}p" $1)"
    case "$l" in
      "#"*)
        continue
        ;;
      "Include "*)
        CONFIGDIR="$(dirname $CONFIG_FILE)"
        (
        cd ${CONFIGDIR};
        INCLUDED_FILE="$(echo "$l" | sed 's/Include //')";
        for f in $(eval "find ${INCLUDED_FILE}" 2> /dev/null); do
          [ -f "${f}" ] && PARENT_CONFIG="$CONFIG_FILE" CONFIG_FILE="$f" \
            _read_cfg $f
        done
        )
        ;;
      "["[^]]*"]"*) # [SECTION] TAGS
        SECTION_NAME="$(echo "$l" | sed 's/.*\[\(.*\)\].*/\1/')"
        SECTION_TAGS="$(echo "$l" | sed 's/.*\]\(.*\)$/\1/')"
        ;;
      [^,]*","[^,]*) # Val, Val
        [ -z "${SECTION_NAME}" ] &&  echo "Error : missing [section] $i: $l" && exit 1
        VALUE1="$(echo $(echo "$l" | cut -d, -f1))"
        VALUE2="$(echo $(echo "$l" | cut -d, -f2))"
        [ -z "${VALUE1}" ] && echo "Error : value1 missing $i : $l" && exit 1
        [ -z "${VALUE2}" ] && echo "Error : value2 missing $i : $l" && exit 1
        VALUE1="$(echo "$VALUE1" | sed "s|^~/|$HOME/|")"
        VALUE2="$(echo "$VALUE2" | sed "s|^~/|$HOME/|")"
        if [ "$_tags" ]; then
          _found=
          for _tag in $_tags; do
              for _ctag in $SECTION_TAGS; do
                  if [ "${_tag}" = "${_ctag}" ]; then
                    _found=t
                    break
                  fi
              done
              [ "$_found" ] && break
          done
          [ "$_found" ] || continue
        fi
        _process_line "${SECTION_NAME}" "${VALUE1}" "${VALUE2}"
        ;;
      "")
        ;;
      *)
        echo "ERROR : invalid line $i : $l"
        exit 2
        ;;
   esac
  done
}

if [ "$_rsync" ]; then
  _ensure_permissions
  echo "(ok, let's go)"
  _ensure_target
  _confirm_sens
fi

export BACKUP_DATE=`date '+%Y%m%d_%H%M%S'`
echo '--------------------------'
printf "OPERATIONS  : "
[ "${_dry_run}" ] && printf 'DRY-RUN; '
[ "${_rsync}" ] && printf "rsync (${_sens:-auto}); "
[ "${_archive}" ] && printf 'archive; '
[ "${_relink}" ] && printf 'import links; '
[ "${_yes}" ] && printf 'yes '
echo
[ "${_tags}" ]  && echo "TAGS        : ${_tags}"
[ "${TARGET}" ] && echo "TARGET      : ${TARGET}"
echo '--------------------------'
if [ "$_merge_a" ]; then
  echo "MERGING ${_merge_a} with ${_merge_b}"
  _run meld "${_merge_a}" "${_merge_b}"
  _diff_rq "${_merge_a}" "${_merge_b}" || echo "##~~~ MERGE is incomplete"
else
  _read_cfg ${CONFIG_FILE}
fi

echo "########## DONE ##########"
exit 0
