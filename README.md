# do_backup
## usage
Plug in your encrypted USB key.
Enter `do_backup.sh`.
Confirm actions.
Unplug your USB key.

## configuration
A configuration file looks like that.
```ini
  [section] tag*
  Source, Target
  #
  # Except for rsync sections,
  # where Target shall be relative to $TARGET,
  # both Source and Target shall be absolute.
  #
  # You can use '~', ${variable} and $(command)
  # for describing absolute path
  #
  # TARGET is either explicitely specified (-t option)
  #        or /media/root/<usb_uuid>/.backup
  #

  Include another.file
```
The script look for these files (ordered by priority):
  - `~/.do_backup.cfg`
  - `~/.config/do_backup/directories.$HOSTNAME`
  - `~/.config/do_backup/directories`

Once a file found, it use it and ignore others.
You can explicitely choose the configuration by prepending script call with `CONFIG=${MY_CFG_FILE}`.

The aim is either to say explicitely what to import/export in `~/.do_backup.cfg` or to setup different synchronization according to hostname `~/.config/do_backup/directories.$HOSTNAME`.

Configuration file example:
```ini
  [rsync]
  /local/dir, dir
  # will rsync /local/dir to $TARGET/dir
  ~/dirb, dirb
  # will rsync $HOME/dirb to $TARGET/dirb

  [rsync] EVERYDAY FAST CONFIG
  /local/dirc, dirc
  # if you call `do_backup.sh EVERYDAY`,
  # only the lines in this section will be processed.

  #just archive
  [archive]
  /local/dir, /archives/dir.zip
  # will zip /local/dir in $TARGET/dir.zip

  #rebuild links
  [link]
  ~/.dir, /local/dir
  # make ln -s ~/.dir /local/dir

  #extends in many ways
  Include ./directories.${HOSTNAME}.${USER}
  # ./ is relative to the current config file
  Include $(find /etc/do_backup/ -name 'directories.*')
```
