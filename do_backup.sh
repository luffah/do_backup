#!/bin/sh
_tags=""
_sens=""
_relink=
_rsync=t
_archive=t
_dry_run=
_force=
_yes=

HOSTNAME=$(hostname)
usage () {
    cat <<EOUSE
Config files (ordered by priority):
  ~/.do_backup.cfg
  ~/.config/do_backup/directories.${HOSTNAME}
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

Usage: $(basename $0) [-t /remote/dir] [TAG*] OPTIONS

Options:
    -t REMOTE_DIR     -- A directory containing the .backup dir
    --dry-run         -- Dry run : no effect
    --yes             -- Don't ask questions

Related to [rsync] sections:
    -b|-backup        -- Backup  (local  -> remote)
    -r|-restore       -- Restore (remote -> local )

Related to [archive] sections:
    -a|--archive      -- Perform archiving part (no sync)
    -noa|--no-archive -- Disable archiving

Related to [link] sections:
    -rl|--relink     -- Import links (no sync)
EOUSE
}
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
    --dry-run)
      _dry_run=t
      ;;
    -y*|--yes)
      _yes=t
      ;;
    -h)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option : $1"
      exit 1
      ;;
    /*)
      TARGET="${1}"
      ;;
    *)
      _tags="${_tags} ${1}"
      ;;
  esac
  shift
done
if [ -z "$CONFIG" ]; then
  [ ! -f "${CONFIG}" ] && CONFIG="${HOME}/.do_backup.cfg"
  [ ! -f "${CONFIG}" ] && CONFIG="${HOME}/.config/do_backup/directories.${HOSTNAME}"
  [ ! -f "${CONFIG}" ] && CONFIG="${CONFIG_PATH}/directories.${HOSTNAME}"
  [ ! -f "${CONFIG}" ] && CONFIG="${HOME}/.config/do_backup/directories"
  [ ! -f "${CONFIG}" ] && CONFIG="${CONFIG_PATH}/directories"
fi
[ ! -f "${CONFIG}" ] && echo "Configuration file is required." && exit 1

if [ "$_rsync" ]; then

  if [ "`whoami`" != "root" ]; then
    if [ -z "${TARGET}" -o ! -d "${TARGET}" ]; then
       echo "(superuser access is needed to launch this script)" 
       sudo \
         TARGET=${TARGET} \
         HOME=${HOME} \
         CONFIG="${CONFIG}" \
         sh -- $0 $_all_opts
       exit $?
    fi
  fi

  echo "(ok, let's go)"

  if [ -z "${TARGET:-}" ]
  then

    for i in /dev/sd[bcd][1234]
    do
      if udisksctl info -b $i | grep crypto_ > /dev/null
      then
        LUKSDEV="$i"
        # LUKSUUID=$(udisksctl info -b $i | awk '/IdUUID:/ {print $2}')
        break
      fi
    done

    echo "Using first crypto device found : ${LUKSDEV}"

    if [ -z "$LUKSDEV" ]; then echo "No luks dev found"; exit 1; fi

    DEV=$(udisksctl unlock -b $LUKSDEV 2>&1 | sed -n 's|.*as [^/]*\(/[-a-zA-Z0-9/]\+\)[^-a-zA-Z0-9/]*.*|\1|p')
    TARGET=$(udisksctl mount -b $DEV 2>&1 | sed -n 's|.* at [^/]*\(/[-a-zA-Z0-9/]\+\)[^-a-zA-Z0-9/]*.*|\1|p')

    echo "${LUKSDEV} -> ${DEV} -> ${TARGET}"

    umount_dev(){
      udisksctl unmount -b ${DEV}
      echo "eject device ? [Y/n]"
      read ret
      if [ "${ret}" != "n" ]; then
        udisksctl lock -b ${LUKSDEV}
        udisksctl power-off -b ${LUKSDEV}
      fi
      exit 1
    }
    trap umount_dev 1 2 3 6 9
    [ -z "${TARGET}" -o ! -d "${TARGET}" ] && umount_dev && exit 1
    TARGET="$TARGET/.backup"
  fi
  mkdir -p $TARGET
  export TARGET

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

fi

_run(){
  if [ "${_dry_run}" ]; then
    echo "+ $@"
  else
    $@
  fi
}

check_filesystems(){
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
    echo "> Retry [Y/n] ?"
    rep=""; read rep; if [ -z "${rep}" -o "${rep}" = "yes" ]
    then
      check_consistancy $1 $2
      return $?
    fi
  fi
  return $ret
}

rsync_touch(){
  _localdir=$1
  _remotedir=$2
  _reuse_touch=""
  _noconfirm=""
  _pass=""
  check_consistancy "${_localdir}/.backup_touch" "${_remotedir}/.backup_touch"
  _consistancy=$?
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
            echo "> Do you want to move it before overiding data ? [Y/n]"
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
        echo "> Rsync [Y/n/d/r] ? (Yes by default; no to skip; d to diff; r to revert)"
        read  rep
        if [ "${rep}" = "d" ]
        then
          tmpfile="`mktemp`"
          LANG='EN' diff -rq ${_from} ${_to} > ${tmpfile}
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
          echo "> Rsync [Y/n/r] ? (Yes by default; no to skip ; r to revert)"
          read  rep
        fi
        if [ "${rep}" = "r" ]
        then
          _tmp="${_from}"
          _from="${_to}"
          _to="${_tmp}"
          echo "# From        : ${_from}"
          echo "# To          : ${_to}"
          echo "> Rsync [Y/n] ? (Yes by default; no to skip)"
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
      echo "Setup the link (move files and create the link) ? [y/N]"
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
        echo "( break link with `readlink ${f_link}` )[Y/n]"
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
      echo "Do you want to resolve the conflict ? [y/N]"
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
        CONFIGDIR="$(dirname $CONFIG)"
        (
        cd ${CONFIGDIR};
        INCLUDED_FILE="$(echo "$l" | sed 's/Include //')";
        for f in $(eval "echo ${INCLUDED_FILE}" 2> /dev/null); do
          [ -f "${f}" ] && PARENT_CONFIG="$CONFIG" CONFIG="$f" \
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
_read_cfg ${CONFIG}
echo "########## DONE ##########"
exit 0

