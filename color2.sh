

declare -A col_length col_colored;
apost=$(echo -e "\u0027");
delim=$(git config alias.delim);
git_log_cmd=$(git config alias.$1);
# graph_col=${2:-$(git config alias.$1-col)};
# color_list=( $(git config alias.color-list) );
[[ -z "$graph_col" ]] && graph_col=1;
[[ -z "$git_log_cmd" ]] && { git $1;exit; };

i=0;
n=0;
while IFS= read -r line; do
  ((n++));
  while read -d"$delim" -r col_info;do
    ((i++));
    [[ -z "$col_info" ]] && col_length["$n:$i"]=${col_length["${last[$i]:-1}:$i"]} && ((i--)) && continue;
    [[ $i -gt ${i_max:-0} ]] && i_max=$i;
    [[ "${col_info:1:1}" = "C" ]] && col_colored["$n:$i"]=1;
    col_length["$n:$i"]=$(grep -Eo "\([0-9]*,[lm]*trunc\)" <<< "$col_info" | grep -Eo "[0-9]*" | head -n 1);
    [[ -n "${col_length["$n:$i"]}" ]] && last[$i]=$n;
    chars_extra=$(grep -Eo "\trunc\).*" <<< "$col_info");
    chars_extra=${chars_extra#trunc)};
    chars_begin=${chars_extra%%\%*};
    chars_extra=${chars_extra%$apost*};
    chars_extra=${chars_extra#*\%};
   case " ad aD ae aE ai aI al aL an aN ar as at b B cd cD ce cE ci cI cl cL cn cN cr cs ct d D e f G? gd gD ge gE GF GG GK gn gN GP gs GS GT h H N p P s S t T " in
     *" ${chars_extra:0:2} "*)
       chars_extra=${chars_extra:2};
       chars_after=${chars_extra%%\%*};
       ;;
     *" ${chars_extra:0:1} "*)
       chars_extra=${chars_extra:1};
       chars_after=${chars_extra%%\%*};
       ;;
     *)
       echo "No Placeholder found. Probably no table-like output.";
       continue;
       ;;
   esac;
   if [[ -n "$chars_begin$chars_after" ]];then
     len_extra=$(echo "$chars_begin$chars_after" | wc -m);
     col_length["$n:$i"]=$((${col_length["$n:$i"]}+$len_extra-1));
   fi;
 done <<< "${line#*=format:}$delim";
 i=1;
done <<< "$(echo -e "${git_log_cmd//\%n/\\n}")";

git_log_fst_part="${git_log_cmd%%"$apost"*}";
git_log_lst_part="${git_log_cmd##*"$apost"}";
git_log_tre_part="${git_log_cmd%%"$delim"*}";
git_log_tre_part="${git_log_tre_part##*"$apost"}";
git_log_cmd_count="$git_log_fst_part$apost $git_log_tre_part$apost$git_log_lst_part";
col_length["1:1"]=$(eval git "${git_log_cmd_count// --color}" | wc -L);

i=0;
while IFS="$delim" read -r graph rest;do
  ((i++));
  graph_line[$i]="$graph";
done < <(eval git "${git_log_cmd/ --color}" && echo);

i=0;
l=0;
msg_err=;
color_list_ind=-1;
color_list_num=${#color_list[*]};
color_repeat_ind=1;
if [[ $color_list_num -eq 0 ]];then
  echo "No tree colors specified via color-list under section [alias] in your .gitconfig";
  echo "Therefore collecting available Git colors, which may take a while ...";
  while read -d"[" -r char;do
    color=$(sed -nl99 "l" <<< "$char");
    case "$color" in
      *"m"*)
        color=${color%%m*};
        ;;
      *)
        continue;
        ;;
    esac;
    case " $color_list " in
      *" $color "*)
        continue;
        ;;
      *)
        color_list="$color_list$color ";
        ;;
    esac;
  done <<< "$(git log --all --color --graph --pretty=format:)";
  echo -e "Temporary used color-list = \"${color_list% }\"\n";
  color_list=( ${color_list% } );
  color_list_num=${#color_list[*]};
fi;
while IFS= read -r line;do
  ((i++));
  j=-1;
  case_off=;
  graph_colored=;
  graph_line_last="${graph_line[$i-1]}";
  graph_line="${graph_line[$i]}";
  graph_line_next="${graph_line[$i+1]}";
  while IFS= read -r char;do
    ((j++));
    case "$case_off$char" in
      [^\ \_\*\/\|\\]|"case_off"*)
        graph_colored="${graph_colored}\033[${point_color}m$char\033[0m";
        case_off="case_off";
        ;;
      " ")
        graph_colored="${graph_colored}$char";
        case "$char_last" in
          " ")
            unset color_ind[$j];
            ;;
        esac;
        ;;
      "*")
        case "${graph_line_last:$j:1}" in
          "*")
            :;
            ;;
          "|")
            case "${graph_line_last:$(($j-1)):1}" in
              "\\")
                color_ind[$j]=${color_ind_last[$j-1]:-${color_ind[$j-1]}};
                ;;
              *)
                :;
                ;;
            esac;
            ;;
          " ")
            case "${graph_line_last:$(($j-1)):1}" in
              "\\")
                color_ind[$j]=${color_ind_last[$j-1]:-${color_ind[$j-1]}};
                ;;
              "/")
                case "${graph_line_last:$(($j+1)):1}" in
                  "/")
                    color_ind[$j]=${color_ind[$j+1]};
                    ;;
                  " ")
                    new_col_ind=${#color[*]};
                    while true;do
                      ((color_list_ind++));
                      [[ $color_list_ind -ge $color_list_num ]] && color_list_ind=$color_repeat_ind;
                      [[ $color_list_ind -ge $color_list_num ]] && break;
                      new_color=${color_list[$color_list_ind]};
                      case "$new_color" in
                        ""|[\ ]*)
                          continue;
                          ;;
                        "${color[${color_ind[$j-1]}]}")
                          [[ $(($color_list_num-$color_repeat_ind)) -gt 1 ]] && continue;
                          ;;&
                        *)
                          color[$new_col_ind]=$new_color;
                          color_ind[$j]=$new_col_ind;
                          last_new_colored_line=$i;
                          break;
                          ;;
                      esac 2>/dev/null;
                    done;
                    ;;
                  *)
                    [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
                    ;;
                esac;
                ;;
              " ")
                case "${graph_line_last:$(($j+1)):1}" in
                  "/")
                    color_ind[$j]=${color_ind[$j+1]};
                    ;;
                  *)
                    new_col_ind=${#color[*]};
                    while true;do
                      ((color_list_ind++));
                      [[ $color_list_ind -ge $color_list_num ]] && color_list_ind=$color_repeat_ind;
                      [[ $color_list_ind -ge $color_list_num ]] && break;
                      new_color=${color_list[$color_list_ind]};
                      case "$new_color" in
                        ""|[\ ]*)
                          continue;
                          ;;
                        "${color[${color_ind[$j-1]}]}")
                          [[ $(($color_list_num-$color_repeat_ind)) -gt 1 ]] && continue;
                          ;;&
                        *)
                          color[$new_col_ind]=$new_color;
                          color_ind[$j]=$new_col_ind;
                          last_new_colored_line=$i;
                          break;
                          ;;
                      esac 2>/dev/null;
                    done;
                    ;;
                esac;
                ;;
              *)
                [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
                ;;
            esac;
            ;;
          ""|[^\ \_\*\/\|\\])
            new_col_ind=${#color[*]};
            while true;do
              ((color_list_ind++));
              [[ $color_list_ind -ge $color_list_num ]] && color_list_ind=$color_repeat_ind;
              [[ $color_list_ind -ge $color_list_num ]] && break;
              new_color=${color_list[$color_list_ind]};
              case "$new_color" in
                ""|[\ ]*)
                  continue;
                  ;;
                "${color[${color_ind[$j-1]}]}")
                  [[ $(($color_list_num-$color_repeat_ind)) -gt 1 ]] && continue;
                  ;;&
                *)
                  color[$new_col_ind]=$new_color;
                  color_ind[$j]=$new_col_ind;
                  last_new_colored_line=$i;
                  break;
                  ;;
              esac 2>/dev/null;
            done;
            ;;
          *)
            [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
            ;;
        esac;
        graph_colored="${graph_colored}\033[${color[${color_ind[$j]}]}m$char\033[0m";
        point_color=${color[${color_ind[$j]}]};
        ;;
      "|")
        case "${graph_line_last:$j:1}" in
          " ")
            case "${graph_line_last:$(($j-1)):1}" in
              "/")
                color_ind[$j]=${color_ind[$j+1]};
                ;;
              "\\")
                color_ind[$j]=${color_ind_last[$j-1]:-${color_ind[$j-1]}};
                ;;
              *)
                case "${graph_line_last:$(($j+1)):1}" in
                  "/")
                    color_ind[$j]=${color_ind[$j+1]};
                    ;;
                  *)
                    [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
                    ;;
                esac;
                ;;
            esac;
            ;;
          "|")
            case "${graph_line_last:$(($j-1)):1}" in
              "\\")
                case "${graph_line:$(($j+1)):1}" in
                  "\\")
                     :;
                     ;;
                   " ")
                    color_ind[$j]=${color_ind_last[$j-1]};
                    ;;
                  *)
                    [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
                    ;;
                esac;
                ;;
              *)
                :;
                ;;
            esac;
            ;;
          "*")
            case "${graph_line:$(($j-1)):1}" in
              "/")
                if [[ $last_new_colored_line -eq $(($i-1)) ]];then
                  new_col_ind=${#color[*]};
                  while true;do
                    ((color_list_ind++));
                    [[ $color_list_ind -ge $color_list_num ]] && color_list_ind=$color_repeat_ind;
                    [[ $color_list_ind -ge $color_list_num ]] && break;
                    new_color=${color_list[$color_list_ind]};
                    case "$new_color" in
                      ""|[\ ]*)
                        continue;
                        ;;
                      "${color[${color_ind[$j-1]}]}")
                        [[ $(($color_list_num-$color_repeat_ind)) -gt 1 ]] && continue;
                        ;;&
                      *)
                        color[$new_col_ind]=$new_color;
                        color_ind[$j]=$new_col_ind;
                        break;
                        ;;
                    esac 2>/dev/null;
                  done;
                else
                  color_ind[$j]=${color_ind_last[$j]};
                fi;
                ;;
              *)
                :;
                ;;
            esac;
            ;;
          "/")
            color_ind[$j]=${color_ind[$j]};
            ;;
          *)
            [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
            ;;
        esac;
        graph_colored="${graph_colored}\033[${color[${color_ind[$j]}]}m$char\033[0m";
        ;;
      "/")
        case "${graph_line_last:$(($j)):1}" in
          "|")
            case "${graph_line_last:$(($j+1)):1}" in
              "/")
                case "${graph_line_next:$j:1}" in
                  "|")
                    color_ind[$j]=${color_ind[$j+1]};
                    ;;
                  " ")
                    color_ind[$j]=${color_ind[$j]};
                    ;;
                  *)
                    [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
                    ;;
                esac;
                ;;
              *)
                color_ind[$j]=${color_ind[$j]};
                ;;
            esac;
            ;;
          *)
            case "${graph_line_last:$(($j+2)):1}" in
              "/"|"_")
                color_ind[$j]=${color_ind[$j+2]};
                ;;
              *)
                case "${graph_line_last:$(($j+1)):1}" in
                  "/"|"_"|"|")
                    color_ind[$j]=${color_ind[$j+1]};
                    ;;
                  "*")
                    case "${graph_line:$(($j+1)):1}" in
                      "|")
                        if [[ $last_new_colored_line -eq $(($i-1)) ]];then
                          color_ind[$j]=${color_ind_last[$j+1]};
                        else
                          new_col_ind=${#color[*]};
                          while true;do
                            ((color_list_ind++));
                            [[ $color_list_ind -ge $color_list_num ]] && color_list_ind=$color_repeat_ind;
                            [[ $color_list_ind -ge $color_list_num ]] && break;
                            new_color=${color_list[$color_list_ind]};
                            case "$new_color" in
                              ""|[\ ]*)
                                continue;
                                ;;
                              "${color[${color_ind[$j-1]}]}")
                                [[ $(($color_list_num-$color_repeat_ind)) -gt 1 ]] && continue;
                                ;;&
                              *)
                                color[$new_col_ind]=$new_color;
                                color_ind[$j]=$new_col_ind;
                                break;
                                ;;
                            esac 2>/dev/null;
                          done;
                        fi;
                        ;;
                      *)
                        color_ind[$j]=${color_ind_last[$j+1]};
                        ;;
                    esac;
                    ;;
                  *)
                    case "${graph_line_last:$j:1}" in
                      "\\")
                        :;
                        ;;
                      " ")
                        case "${graph_line_last:$(($j+1)):1}" in
                          "*")
                            color_ind[$j]=${color_ind[$j+1]};
                            ;;
                          *)
                            [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
                            ;;
                        esac;
                        ;;
                      *)
                        [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
                        ;;
                    esac;
                    ;;
                esac;
                ;;
            esac;
            ;;
        esac;
        graph_colored="${graph_colored}\033[${color[${color_ind[$j]}]}m$char\033[0m";
        ;;
      "\\")
        case "${graph_line_last:$(($j-1)):1}" in
          "|"|"\\")
            color_ind[$j]=${color_ind_last[$j-1]:-${color_ind[$j-1]}};
            ;;
          "*")
            new_col_ind=${#color[*]};
            while true;do
              ((color_list_ind++));
              [[ $color_list_ind -ge $color_list_num ]] && color_list_ind=$color_repeat_ind;
              [[ $color_list_ind -ge $color_list_num ]] && break;
              new_color=${color_list[$color_list_ind]};
              case "$new_color" in
                ""|[\ ]*)
                  continue;
                  ;;
                "${color[${color_ind[$j-1]}]}")
                  [[ $(($color_list_num-$color_repeat_ind)) -gt 1 ]] && continue;
                  ;;&
                *)
                  color[$new_col_ind]=$new_color;
                  color_ind[$j]=$new_col_ind;
                  break;
                  ;;
              esac 2>/dev/null;
            done;
            ;;
          " ")
            case "${graph_line_last:$(($j-2)):1}" in
              "\\"|"_")
                color_ind[$j]=${color_ind_last[$j-2]:-${color_ind[$j-2]}};
                ;;
              *)
                case "${graph_line_last:$j:1}" in
                  "|")
                    color_ind[$j]=${color_ind_last[$j]:-${color_ind[$j]}};
                    ;;
                  *)
                    [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
                    ;;
                esac;
                ;;
            esac;
            ;;
          *)
            [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
            ;;
        esac;
        graph_colored="${graph_colored}\033[${color[${color_ind[$j]}]}m$char$char\033[0m";
        ;;
      "_")
        case "${graph_line:$(($j-2)):1}" in
          "\\"|"_")
            color_ind[$j]=${color_ind[$j-2]};
            ;;
          " "|"/")
            k=2;
            while [[ "${graph_line:$(($j+$k)):1}" = "_" ]];do
              k=$(($k+2));
            done;
            case "${graph_line:$(($j+$k)):1}" in
              "/")
                case "${graph_line_last:$(($j+$k+1)):1}" in
                  "*")
                    color_ind[$j]=${color_ind[$j+$k+1]};
                    ;;
                  " ")
                    case "${graph_line_last:$(($j+$k)):1}" in
                      "\\")
                        color_ind[$j]=${color_ind[$j+$k]};
                        ;;
                      *)
                        [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
                        ;;
                    esac;
                    ;;
                  "|")
                    case "${graph_line:$(($j+$k+1)):1}" in
                      "|")
                        color_ind[$j]=${color_ind[$j+$k+2]};
                        ;;
                      " ")
                        color_ind[$j]=${color_ind[$j+$k+1]};
                        ;;
                      *)
                        [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
                        ;;
                    esac;
                    ;;
                  *)
                    [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
                    ;;
                esac;
                ;;
              *)
                [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
                ;;
            esac;
            ;;
          *)
            [[ -n "$msg_err" ]] && echo -e "Unknown case in graph_line $i: $graph_line for char $char at position $j with the former graph_line $(($i-1)): $graph_line_last";
            ;;
        esac;
        graph_colored="${graph_colored}\033[${color[${color_ind[$j]}]}m$char\033[0m";
        ;;
    esac;
    char_last=$char;
  done <<< "$(grep -Eo "." <<< "${graph_line%%$delim*}")";
  for key in ${!color_ind[*]};do
    color_ind_last[$key]=${color_ind[$key]};
  done;


  c=0;
  ((l++));
  [[ $l -gt $n ]] && l=1;
  while IFS= read -d"$delim" -r col_content;do
    ((c++));
    [[ $c -le $graph_col ]] && c_corr=-1 || c_corr=0;
    if [[ $c -eq 1 ]];then
      [[ "${col_content/\*}" = "$col_content" ]] && [[ $l -eq 1 ]] && l=$n;
      whitespaces=$(seq -s" " $((${col_length["1:1"]}-$j))|tr -d "[:digit:]");
      col_content[$graph_col]="${graph_colored}$whitespaces";
    elif [[ ${col_colored["$l:$c"]:-0} -eq 0 ]];then
      col_content[$c+$c_corr]="\033[${point_color:-0}m$(printf "%-${col_length["$l:$c"]}s" "${col_content:-""}")\033[0m";
    else
      col_content[$c+$c_corr]="$(printf "%-${col_length["$l:$c"]}s" "${col_content:-""}")";
    fi;
  done <<< "$line$delim";
  for ((k=$c+1;k<=$i_max;k++));do
    [[ $k -le $graph_col ]] && c_corr=-1 || c_corr=0;
    col_content[$k+$c_corr]="$(printf "%-${col_length["$l:$k"]:-${col_length["${last[$k]:-1}:$k"]:-0}}s" "")";
  done;
  unset col_content[0];
  echo -e "${col_content[*]}";
  unset col_content[*];
done < <(git $1 && echo);

