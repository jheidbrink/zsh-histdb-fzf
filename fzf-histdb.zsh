FZF_HISTDB_FILE="${(%):-%N}"

# use gdate if available (will provide nanoseconds on mac)
if command -v gdate >> /dev/null; then
  datecmd='gdate'
else
  datecmd='date'
fi

get_date_format() (
    local date_format

    date_format="$(awk '{ print tolower($1) }' <<< "${HISTDB_FZF_FORCE_DATE_FORMAT}")"

    if [[ "${date_format}" != "us" && "${date_format}" != "non-us" ]]; then
        eval "$(locale)"
        local lc_time_lang="$(awk -F'.' '{ print tolower($1) }' <<< "${LC_TIME}")"
        if [[ "${lc_time_lang}" == "en_us" || "${lc_time_lang}" == "c" ]]; then
            date_format="us"
        else
            date_format="non-us"
        fi
    fi

    if [[ "${date_format}" == "us" ]]; then
        echo "%m/%d"
    else
        echo "%d/%m"
    fi
)

# variables for substitution in log
NL="
"
NLT=$(printf "\n\t\t")

autoload -U colors && colors

histdb-fzf-log() {
  if [[ ! -z ${HISTDB_FZF_LOGFILE} ]]; then
    if [[ ! -f ${HISTDB_FZF_LOGFILE} ]]; then
      touch ${HISTDB_FZF_LOGFILE}
    fi
    printf "%s %s\n" $(${datecmd} +'%s.%N') ${*//$NL/$NLT} >> ${HISTDB_FZF_LOGFILE}
  fi
}


histdb-fzf-query(){
  # A wrapper for histb-query with fzf specific options and query
  _histdb_init

  local where=""
	local cols="history.id as id, commands.argv as argv, max(start_time) as max_start, exit_status"
	local groupby="group by history.command_id, history.place_id"
  local date_format="$(get_date_format)"
  local mst="datetime(max_start, 'unixepoch')"
  local dst="datetime('now', 'start of day')"
  local yst="datetime('now', 'start of year')"
  local timecol="strftime(
                   case when $mst > $dst then
                      '%H:%M'
                   else (
                     case when $mst > $yst then
                       '${date_format}'
                     else
                       '${date_format}/%Y'
                     end)
                   end,
                   max_start,
                   'unixepoch',
                   'localtime') as time"

  local query="
      select
      id,
      ${timecol},
      CASE exit_status WHEN 0 THEN '' ELSE '${fg[red]}' END || replace(argv, '$NL', ' ') as cmd,
      CASE exit_status WHEN 0 THEN '' ELSE '${reset_color}' END
      from
      ( select
          ${cols}
        from
          history
        left join
				  commands on history.command_id = commands.id
        left join
				  places on history.place_id = places.id
				${where:+where ${where}}
				${groupby}
				order
				  by max_start desc
			)
      order by max_start desc"

  histdb-fzf-log "query for log '${(Q)query}'"

  # use Figure Space U+2007 as separator
  _histdb_query -separator ' ' "$query"
  histdb-fzf-log "query completed"
}

histdb-detail(){
  HISTDB_FILE=$1
  local where="(history.id == '$(sed -e "s/'/''/g" <<< "$2" | tr -d '\000')')"

  local date_format="$(get_date_format)"

  local cols="
    history.id as id,
    commands.argv as argv,
    max(start_time) as max_start,
    exit_status,
    duration as secs,
    count() as runcount,
    history.session as session,
    places.host as host,
    places.dir as dir"

  local query="
    select
      strftime('${date_format}/%Y %H:%M', max_start, 'unixepoch', 'localtime') as time,
      ifnull(exit_status, 'NONE') as exit_status,
      ifnull(secs, '-----') as secs,
      ifnull(host, '<somewhere>') as host,
      ifnull(dir, '<somedir>') as dir,
      session,
      id,
      argv as cmd
    from
      (select ${cols}
      from
        history
        left join commands on history.command_id = commands.id
        left join places on history.place_id = places.id
      where ${where})
  "

  array_str=("${$(sqlite3 -cmd ".timeout 1000" "${HISTDB_FILE}" -separator " " "$query" )}")
  array=(${(@s: :)array_str})

  histdb-fzf-log "DETAIL: ${array_str}"

  # Add some color
  if [[ "${array[2]}" == "NONE" ]];then
    #Color exitcode magento if not available
    array[2]=$(echo "\033[35m${array[2]}\033[0m")
  elif [[ ! ${array[2]} ]];then
    #Color exitcode red if not 0
    array[2]=$(echo "\033[31m${array[2]}\033[0m")
  fi
  if [[ "${array[3]}" == "-----" ]];then
    #Color duration magento if not available
    array[3]=$(echo "\033[35m${array[3]}\033[0m")
  elif [[ "${array[3]}" -gt 300 ]];then
    # Duration red if > 5 min
    array[3]=$(echo "\033[31m${array[3]}\033[0m")
  elif [[ "${array[3]}" -gt 60 ]];then
    # Duration yellow if > 1 min
    array[3]=$(echo "\033[33m${array[3]}\033[0m")
  fi

  printf "\033[1mLast run(%s)\033[0m (%s): %s, %s s\n%s:%s (session %s) "  ${array[2]}  ${array[7]} ${array[0]}  ${array[1]}  ${array[3]} ${array[4]} ${array[5]} ${array[6]}
  echo "${array[8,-1]}"
}

histdb-get-command(){
  HISTDB_FILE=$1
  CMD_ID=$2

  local query="
    select
      argv as cmd
    from
      history
      left join commands on history.command_id = commands.id
    where
      history.id='${CMD_ID}'
  "
  printf "%s" "$(sqlite3 -cmd ".timeout 1000" "${HISTDB_FILE}" "$query")"
}

histdb-fzf-widget() {
  local selected exitkey
  ORIG_FZF_DEFAULT_OPTS=$FZF_DEFAULT_OPTS
  query=${BUFFER}
  origquery=${BUFFER}
  histdb-fzf-log "================== START ==================="
  histdb-fzf-log "original buffers: -:$BUFFER l:$LBUFFER r:$RBUFFER"
  histdb-fzf-log "original query $query"
  histdb_fzf_modes=('session' 'loc' 'global' 'everywhere')

  exitkey='ctrl-r'
  setopt localoptions noglobsubst noposixbuiltins pipefail 2> /dev/null
  # Here it is getting a bit tricky, fzf does not support dynamic updating so we have to close and reopen fzf when changing the focus (session, dir, global)
  # so we check the exitkey and decide what to do
  while [[ "$exitkey" != "" && "$exitkey" != "esc" ]]; do
    histdb-fzf-log "------------------- TURN -------------------"
    histdb-fzf-log "Exitkey $exitkey"
    # based on the mode, we use the options for histdb options

    # log the FZF arguments
    OPTIONS="$ORIG_FZF_DEFAULT_OPTS
      --ansi
      --delimiter=' '
      -n2.. --with-nth=2..
      --tiebreak=index --expect='esc,ctrl-r'
      --bind 'ctrl-d:page-down,ctrl-u:page-up'
      --print-query
      --preview='source ${FZF_HISTDB_FILE}; histdb-detail ${HISTDB_FILE} {1}' --preview-window=up:20%:wrap
      --no-hscroll
      --query='${query}' +m"

    histdb-fzf-log "$OPTIONS"

    # TODO: behind the -t I need -a or not (which one is grouped?)
    result=( "${(@f)$( histdb-fzf-query -t | FZF_DEFAULT_OPTS="${OPTIONS}" fzf)}" )
    # here we got a result from fzf, containing all the information, now we must handle it, split it and use the correct elements
    histdb-fzf-log "returncode was $?"
    query=$result[1]
    exitkey=${result[2]}
    fzf_selected="${(@s: :)result[3]}"
    fzf_selected="${${(@s: :)result[3]}[1]}"
    histdb-fzf-log "Query was      ${query:-<nothing>}"
    histdb-fzf-log "Exitkey was    ${exitkey:-<NONE>}"
    histdb-fzf-log "fzf_selected = $fzf_selected"

  done
  if [[ "$exitkey" == "esc" ]]; then
    BUFFER=$origquery
  else
    histdb-fzf-log "histdb-get-command ${HISTDB_FILE} ${fzf_selected}"
    selected=$(histdb-get-command ${HISTDB_FILE} ${fzf_selected})
    histdb-fzf-log "selected = $selected"
    BUFFER=$selected
  fi
  CURSOR=$#BUFFER
  zle redisplay
  histdb-fzf-log "new buffers: -:$BUFFER l:$LBUFFER r:$RBUFFER"
  histdb-fzf-log "=================== DONE ==================="
}
zle     -N   histdb-fzf-widget
bindkey '^R' histdb-fzf-widget
