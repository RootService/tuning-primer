#!/bin/sh

################################################################################
#                                                                              #
#    MySQL performance tuning primer script                                    #
#    Writen by: Matthew Montgomery                                             #
#    Report bugs to: https://bugs.launchpad.net/mysql-tuning-primer            #
#    Inspired by: MySQLARd (http://gert.sos.be/demo/mysqlar/)                  #
#    Version: 1.6-r1         Released: 2011-08-06                              #
#    Licenced under GPLv2                                                      #
#                                                                              #
################################################################################

################################################################################
#                                                                              #
#    MySQL performance tuning primer script                                    #
#    Rewritten by: Markus Kohlmeyer                                            #
#    Download: https://github.com/RootService/tuning-primer                    #
#    Report bugs to: https://github.com/RootService/tuning-primer/issues       #
#    Changelog: https://github.com/RootService/tuning-primer/commits           #
#    Version: 2.0.1-r1    Released: 2017-06-07                                 #
#    Licenced under GPLv2                                                      #
#    https://github.com/RootService/tuning-primer/blob/master/LICENSE          #
#                                                                              #
################################################################################

################################################################################
#                                                                              #
#    Usage: ./tuning-primer.sh [ mode ]                                        #
#                                                                              #
#    Available Modes:                                                          #
#        all :           perform all checks (default)                          #
#        prompt :        prompt for login credintials and socket               #
#                        and execution mode                                    #
#        mem, memory :   run checks for tunable options which                  #
#                        effect memory usage                                   #
#        disk, file :    run checks for options which effect                   #
#                        i/o performance or file handle limits                 #
#        innodb :        run InnoDB checks /* to be improved */                #
#        misc :          run checks for that don't categorise                  #
#                        well Slow Queries, Binary logs,                       #
#                        Used Connections and Worker Threads                   #
#                                                                              #
################################################################################
#                                                                              #
#    Set this socket variable ONLY if you have multiple instances running      #
#    or we are unable to find your socket, and you don't want to to be         #
#    prompted for input each time you run this script.                         #
#                                                                              #
################################################################################
socket=


export black='\033[0m'
export boldblack='\033[1;0m'
export red='\033[31m'
export boldred='\033[1;31m'
export green='\033[32m'
export boldgreen='\033[1;32m'
export yellow='\033[33m'
export boldyellow='\033[1;33m'
export blue='\033[34m'
export boldblue='\033[1;34m'
export magenta='\033[35m'
export boldmagenta='\033[1;35m'
export cyan='\033[36m'
export boldcyan='\033[1;36m'
export white='\033[37m'
export boldwhite='\033[1;37m'


for bin in awk bc du find grep head ls mysql mysqladmin netstat sleep sysctl tput uname ; do
    which "$bin" > /dev/null
    if [ "$?" = "0" ] ; then
        bin_path="$(which $bin)"
        export bin_$bin="$bin_path"
    else
        echo "Error: Needed command \"$bin\" not found in PATH!"
        exit 1
    fi
done


cecho ()
## -- Function to easliy print colored text -- ##
{
    local var1="$1" # message
    local var2="$2" # color

    local default_msg="No message passed."

    message="${var1:-$default_msg}"
    color="${var2:-black}"

    case "$color" in
        black)
            printf "$black" ;;
        boldblack)
            printf "$boldblack" ;;
        red)
            printf "$red" ;;
        boldred)
            printf "$boldred" ;;
        green)
            printf "$green" ;;
        boldgreen)
            printf "$boldgreen" ;;
        yellow)
            printf "$yellow" ;;
        boldyellow)
            printf "$boldyellow" ;;
        blue)
            printf "$blue" ;;
        boldblue)
            printf "$boldblue" ;;
        magenta)
            printf "$magenta" ;;
        boldmagenta)
            printf "$boldmagenta" ;;
        cyan)
            printf "$cyan" ;;
        boldcyan)
            printf "$boldcyan" ;;
        white)
            printf "$white" ;;
        boldwhite)
            printf "$boldwhite" ;;
    esac

    printf "%s\n" "$message"
    $bin_tput sgr0
    printf "$black"

    return
}


cechon ()
## -- Function to easliy print colored text -- ##
{
    local var1="$1" # message
    local var2="$2" # color

    local default_msg="No message passed."

    message="${var1:-$default_msg}"
    color="${var2:-black}"

    case "$color" in
        black)
            printf "$black" ;;
        boldblack)
            printf "$boldblack" ;;
        red)
            printf "$red" ;;
        boldred)
            printf "$boldred" ;;
        green)
            printf "$green" ;;
        boldgreen)
            printf "$boldgreen" ;;
        yellow)
            printf "$yellow" ;;
        boldyellow)
            printf "$boldyellow" ;;
        blue)
            printf "$blue" ;;
        boldblue)
            printf "$boldblue" ;;
        magenta)
            printf "$magenta" ;;
        boldmagenta)
            printf "$boldmagenta" ;;
        cyan)
            printf "$cyan" ;;
        boldcyan)
            printf "$boldcyan" ;;
        white)
            printf "$white" ;;
        boldwhite)
            printf "$boldwhite" ;;
    esac

    printf "%s" "$message"
    $bin_tput sgr0
    printf "$black"

    return
}


print_banner ()
## -- Banner -- ##
{
    cecho " -- MYSQL PERFORMANCE TUNING PRIMER 2.0.1-r1 --" boldblue
    cecho "          - By: Matthew Montgomery -" black
    cecho "          - By: Markus Kohlmeyer   -" black
}


check_for_socket ()
## -- Find the location of the mysql.sock file -- ##
{
    if [ -z "$socket" ] ; then
        cnf_socket="$($bin_mysql --print-defaults | $bin_grep -o "socket=[^[:space:]]*" | $bin_awk -F \= '{ print $2 }')"
        if [ -S "$cnf_socket" ] ; then
            socket="$cnf_socket"
        elif [ -S "/var/lib/mysql/mysql.sock" ] ; then
            socket="/var/lib/mysql/mysql.sock"
        elif [ -S "/var/run/mysqld/mysqld.sock" ] ; then
            socket="/var/run/mysqld/mysqld.sock"
        elif [ -S "/tmp/mysql.sock" ] ; then
            socket="/tmp/mysql.sock"
        else
            if [ -S "$ps_socket" ] ; then
                socket="$ps_socket"
            fi
        fi
    fi

    if [ -S "$socket" ] ; then
        echo "UP" > /dev/null
        cmd_mysql="$bin_mysql -S$socket"
        cmd_mysqladmin="$bin_mysqladmin -S$socket"
    else
        cecho "No valid socket file \"$socket\" found!" boldred
        cecho "The mysqld process is not running or it is installed in a custom location." red
        cecho "If you are sure mysqld is running, execute script in \"prompt\" mode or set " red
        cecho "the socket= variable at the top of this script" red
        exit 1
    fi
}


check_mysql_login ()
## -- Test for running mysql -- ##
{
    is_up="$($cmd_mysqladmin ping 2>&1)"
    if [ "$is_up" = "mysqld is alive" ] ; then
        echo "UP" > /dev/null
    elif [ "$is_up" != "mysqld is alive" ] ; then
        cecho " "
        cecho "Using login values from ~/.my.cnf"
        cecho "- INITIAL LOGIN ATTEMPT FAILED -" boldred
        if [ -z "$prompted" ] ; then
            second_login_failed
        else
            return 1
        fi
    else
        cecho "Unknow exit status" red
        exit 1
    fi
}


final_login_attempt ()
## --    -- ##
{
    is_up="$($cmd_mysqladmin ping 2>&1)"
    if [ "$is_up" = "mysqld is alive" ] ; then
        echo "UP" > /dev/null
    elif [ "$is_up" != "mysqld is alive" ] ; then
        cecho "- FINAL LOGIN ATTEMPT FAILED -" boldred
        cecho "Unable to log into socket: $socket" boldred
        exit 1
    fi
}


second_login_failed ()
## -- create a ~/.my.cnf and exit when all else fails -- ##
{
    cecho "Could not auto detect login info!"
    cecho "Found potential sockets: $found_socks"
    cecho "Using: $socket" red

    read -p "Would you like to provide a different socket? [y/N] : " REPLY
    case "$REPLY" in
        yes | y | Y | YES)
            read -p "Socket: " socket
        ;;
    esac

    read -p "Do you have your login handy? [y/N] : " REPLY
    case "$REPLY" in
        yes | y | Y | YES)
            answer1="yes"
            read -p "User: " user
            read -rp "Password: " pass
            if [ -z "$pass" ] ; then
                export cmd_mysql="$bin_mysql -S$socket -u$user"
                export cmd_mysqladmin="$bin_mysqladmin -S$socket -u$user"
            else
                export cmd_mysql="$bin_mysql -S$socket -u$user -p$pass"
                export cmd_mysqladmin="$bin_mysqladmin -S$socket -u$user -p$pass"
            fi
        ;;
        *)
            cecho "Please create a valid login to MySQL"
            cecho "Or, set correct values for 'user=' and 'password=' in ~/.my.cnf"
        ;;
    esac
    cecho " "

    read -p "Would you like me to create a ~/.my.cnf file for you? [y/N] : " REPLY
    case "$REPLY" in
        yes | y | Y | YES)
            answer2="yes"
            if [ ! -f "~/.my.cnf" ] ; then
                umask 077
                printf "[client]\nuser=$user\npassword=$pass\nsocket=$socket" > ~/.my.cnf
                if [ "$answer1" != "yes" ] ; then
                    exit 1
                else
                    final_login_attempt
                    return 0
                fi
            else
                cecho " "
                cecho "~/.my.cnf already exists!" boldred
                cecho " "
                read -p "Replace? [y/N] : " REPLY
                if [ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ] ; then
                    printf "[client]\nuser=$user\npassword=$pass\socket=$socket" > ~/.my.cnf
                    if [ "$answer1" != "yes" ] ; then
                        exit 1
                    else
                        final_login_attempt
                        return 0
                    fi
                else
                    cecho "Please set the 'user=' and 'password=' and 'socket=' values in ~/.my.cnf"
                    exit 1
                fi
            fi
        ;;
        *)
            if [ "$answer1" != "yes" ] ; then
                exit 1
            else
                final_login_attempt
                return 0
            fi
        ;;
    esac
}


mysql_status ()
## -- Function to pull MySQL status variable -- ##
{
    local var1="$1"
    local var2="$2"

    local status="$($cmd_mysql -Bse "SHOW /*!50000 GLOBAL */ STATUS LIKE $var1" | $bin_awk '{ print $2 }')"

    export "$var2"="$status"
}


mysql_variable ()
## -- Function to pull MySQL server runtime variable -- ##
{
    local var1="$1"
    local var2="$2"

    local variable="$($cmd_mysql -Bse "SHOW /*!50000 GLOBAL */ VARIABLES LIKE $var1" | $bin_awk '{ print $2 }')"

    export "$var2"="$variable"
}


mysql_variableTSV ()
## -- Function to pull MySQL server runtime variable -- ##
{
    local var1="$1"
    local var2="$2"

    local variable="$($cmd_mysql -Bse "SHOW /*!50000 GLOBAL */ VARIABLES LIKE $var1" | $bin_awk -F \t '{ print $2 }')"

    export "$var2"="$variable"
}


float2int ()
## -- Convert floating point to integer -- ##
{
    local var1="$1"
    local var2="$2"

    local variable="$(echo "scale=0 ; $var1 / 1" | $bin_bc -l)"

    export "$var2"="$variable"
}


divide ()
## -- Divide two intigers -- ##
{
    local var1="$1"
    local var2="$2"
    local var3="$3"
    local var4="$4"

    usage="$0 dividend divisor '$variable' scale"

    if [ $((var1 >= 1)) -ne 0 ] ; then
        dividend="$var1"
    else
        cecho "Invalid Dividend" red
        cecho "$usage"
        exit 1
    fi

    if [ $((var2 >= 1)) -ne 0 ] ; then
        divisor="$var2"
    else
        cecho "Invalid Divisor" red
        cecho "$usage"
        exit 1
    fi

    if [ ! -n "$var3" ] ; then
        cecho "Invalid variable name" red
        cecho "$usage"
        exit 1
    fi

    if [ -z "$var4" ] ; then
        scale="2"
    elif [ $((var4 >= 0)) -ne 0 ] ; then
        scale="$var4"
    else
        cecho "Invalid scale" red
        cecho "$usage"
        exit 1
    fi

    export "$var3"="$(echo "scale=$scale ; $dividend / $divisor" | $bin_bc -l)"
}


human_readable ()
## -- Make sizes human readable -- ##
{
    local var1="$1"
    local var2="$2"
    local var3="$3"

    scale="$var3"

    if [ $((var1 >= 1073741824)) -ne 0 ] ; then
        if [ -z "$var3" ] ; then
            scale="2"
        fi
        divide "$var1" "1073741824" "$var2" "$scale"
        unit="G"
    elif [ $((var1 >= 1048576)) -ne 0 ] ; then
        if [ -z "$var3" ] ; then
            scale="0"
        fi
        divide "$var1" "1048576" "$var2" "$scale"
        unit="M"
    elif [ $((var1 >= 1024)) -ne 0 ] ; then
        if [ -z "$var3" ] ; then
            scale="0"
        fi
        divide "$var1" "1024" "$var2" "$scale"
        unit="K"
    else
        export "$var2"="$var1"
        unit="bytes"
    fi
}


human_readable_time ()
## -- Make times human readable -- ##
{
    local var1="$1"
    local var2="$2"

    usage="$0 seconds 'variable'"

    if [ -z "$var1" ] || [ -z "$var2" ] ; then
        cecho "$usage" red
        exit 1
    fi

    days="$(echo "scale=0 ; $var1 / 86400" | $bin_bc -l)"
    remainder="$(echo "scale=0 ; $var1 % 86400" | $bin_bc -l)"
    hours="$(echo "scale=0 ; $remainder / 3600" | $bin_bc -l)"
    remainder="$(echo "scale=0 ; $remainder % 3600" | $bin_bc -l)"
    minutes="$(echo "scale=0 ; $remainder / 60" | $bin_bc -l)"
    seconds="$(echo "scale=0 ; $remainder % 60" | $bin_bc -l)"

    export "$var2"="$days days $hours hrs $minutes min $seconds sec"
}


check_mysql_version ()
## -- Print Version Info -- ##
{
    mysql_variable \'version\' mysql_version
    mysql_variable \'version_compile_machine\' mysql_version_compile_machine

    cecho "MySQL Version $mysql_version $mysql_version_compile_machine"
}


post_uptime_warning ()
## -- Warn if uptime not long enough -- ##
{
    mysql_status \'Uptime\' uptime
    mysql_status \'Threads_connected\' threads

    queries_per_sec="$((questions / $uptime))"
    human_readable_time "$uptime" uptimeHR

    cecho "Uptime = $uptimeHR"
    cecho "Avg. qps = $queries_per_sec"
    cecho "Total Questions = $questions"
    cecho "Threads Connected = $threads"
    cecho " "

    if [ $((uptime > 172800)) -ne 0 ] ; then
        cecho "Server has been running for over 48hrs."
        cecho "It should be safe to follow these recommendations"
    else
        cechon "Warning: " boldred
        cecho "Server has not been running for at least 48hrs." boldred
        cecho "It may not be safe to use these recommendations" boldred

    fi
    cecho " "
    cecho "To find out more information on how each of these" red
    cecho "runtime variables effects performance visit:" red
    cecho "http://dev.mysql.com/doc/refman/$major_version/en/server-system-variables.html" boldblue
    cecho "Visit http://www.mysql.com/products/enterprise/advisors.html" boldblue
    cecho "for info about MySQL's Enterprise Monitoring and Advisory Service" boldblue
}


check_slow_queries ()
## -- Slow Queries -- ##
{
    cecho "SLOW QUERIES" boldblue

    mysql_status \'Slow_queries\' slow_queries
    mysql_variable \'long_query_time\' long_query_time
    mysql_variable \'slow_query_log\' log_slow_queries

    prefered_query_time="5"

    if [ "$log_slow_queries" = "ON" ] ; then
        cecho "The slow query log is enabled."
    elif [ "$log_slow_queries" = "OFF" ] ; then
        cechon "The slow query log is "
        cechon "NOT" boldred
        cecho " enabled."
    elif [ -z "$log_slow_queries" ] ; then
        cechon "The slow query log is "
        cechon "NOT" boldred
        cecho " enabled."
    else
        cecho "Error: $log_slow_queries" boldred
    fi
    cecho "Current long_query_time = $long_query_time sec."
    cechon "You have "
    cechon "$slow_queries" boldred
    cechon " out of "
    cechon "$questions" boldred
    cecho " that take longer than $long_query_time sec. to complete"

    float2int "$long_query_time" long_query_timeInt

    if [ $((long_query_timeInt > $prefered_query_time)) -ne 0 ] ; then
        cecho "Your long_query_time may be too high, I typically set this under $prefered_query_time sec." red
    else
        cecho "Your long_query_time seems to be fine" green
    fi
}


check_binary_log ()
## -- Binary Log -- ##
{
    cecho "BINARY UPDATE LOG" boldblue

    mysql_variable \'log_bin\' log_bin
    mysql_variable \'max_binlog_size\' max_binlog_size
    mysql_variable \'max_binlog_cache_size\' max_binlog_cache_size
    mysql_variable \'expire_logs_days\' expire_logs_days
    mysql_variable \'sync_binlog\' sync_binlog

    if [ "$log_bin" = "ON" ] ; then
        cecho "The binary update log is enabled"
        if [ -z "$max_binlog_size" ] ; then
            cecho "The max_binlog_size is not set. The binary log will rotate when it reaches 1GB." red
        fi
        if [ $((expire_logs_days == 0)) -ne 0 ] ; then
            cecho "The expire_logs_days is not set." boldred
            cechon "The mysqld will retain the entire binary log until " red
            cecho "RESET MASTER or PURGE MASTER LOGS commands are run manually" red
            cecho "Setting expire_logs_days will allow you to remove old binary logs automatically"    yellow
            cecho "See http://dev.mysql.com/doc/refman/$major_version/en/purge-master-logs.html" yellow
        fi
        if [ $((sync_binlog == 0)) -ne 0 ] ; then
            cecho "Binlog sync is not enabled, you could loose binlog records during a server crash" red
        fi
    else
        cechon "The binary update log is "
        cechon "NOT " boldred
        cecho "enabled."
        cecho "You will not be able to do point in time recovery" red
        cecho "See http://dev.mysql.com/doc/refman/$major_version/en/point-in-time-recovery.html" yellow
    fi
}


check_used_connections ()
## -- Used Connections -- ##
{
    mysql_status \'Max_used_connections\' max_used_connections
    mysql_status \'Threads_connected\' threads_connected
    mysql_variable \'max_connections\' max_connections

    connections_ratio="$((max_used_connections * 100 / $max_connections))"

    cecho "MAX CONNECTIONS" boldblue
    cecho "Current max_connections = $max_connections"
    cecho "Current threads_connected = $threads_connected"
    cecho "Historic max_used_connections = $max_used_connections"
    cechon "The number of used connections is "
    if [ $((connections_ratio >= 85)) -ne 0 ] ; then
        txt_color="red"
        error="1"
    elif [ $((connections_ratio <= 10)) -ne 0 ] ; then
        txt_color="red"
        error="2"
    else
        txt_color="green"
        error="0"
    fi
    cechon "$connections_ratio% " $txt_color
    cecho "of the configured maximum."

    if [ $((error == 1)) -ne 0 ] ; then
        cecho "You should raise max_connections" $txt_color
    elif [ $((error == 2)) -ne 0 ] ; then
        cecho "You are using less than 10% of your configured max_connections." $txt_color
        cecho "Lowering max_connections could help to avoid an over-allocation of memory" $txt_color
        cecho "See \"MEMORY USAGE\" section to make sure you are not over-allocating" $txt_color
    else
        cecho "Your max_connections variable seems to be fine." $txt_color
    fi
    unset txt_color
}


check_threads ()
## -- Worker Threads -- ##
{
    cecho "WORKER THREADS" boldblue

    mysql_status \'Threads_created\' threads_created1
    $bin_sleep 1
    mysql_status \'Threads_created\' threads_created2

    mysql_status \'Threads_cached\' threads_cached
    mysql_status \'Uptime\' uptime
    mysql_variable \'thread_cache_size\' thread_cache_size

    historic_threads_per_sec="$((threads_created1 / $uptime))"
    current_threads_per_sec="$((threads_created2 - $threads_created1))"

    cecho "Current thread_cache_size = $thread_cache_size"
    cecho "Current threads_cached = $threads_cached"
    cecho "Current threads_per_sec = $current_threads_per_sec"
    cecho "Historic threads_per_sec = $historic_threads_per_sec"

    if [ $((historic_threads_per_sec >= 2)) -ne 0 ] && [ $((threads_cached <= 1)) -ne 0 ] ; then
        cecho "Threads created per/sec are overrunning threads cached" red
        cecho "You should raise thread_cache_size" red
    elif [ $((current_threads_per_sec >= 2)) -ne 0 ] ; then
        cecho "Threads created per/sec are overrunning threads cached" red
        cecho "You should raise thread_cache_size" red
    else
        cecho "Your thread_cache_size is fine" green
    fi
}


check_key_buffer_size ()
## -- Key buffer Size -- ##
{
    cecho "KEY BUFFER" boldblue

    mysql_status \'Key_read_requests\' key_read_requests
    mysql_status \'Key_reads\' key_reads
    mysql_status \'Key_blocks_used\' key_blocks_used
    mysql_status \'Key_blocks_unused\' key_blocks_unused
    mysql_variable \'key_cache_block_size\' key_cache_block_size
    mysql_variable \'key_buffer_size\' key_buffer_size
    mysql_variable \'datadir\' datadir
    mysql_variable \'version_compile_machine\' mysql_version_compile_machine

    myisam_indexes="$($cmd_mysql -Bse "/*!50000 SELECT IFNULL(SUM(INDEX_LENGTH),0) FROM information_schema.tables WHERE ENGINE='MyISAM' */")"

    if [ -z "$myisam_indexes" ] ; then
        myisam_indexes="$($bin_find $datadir -iname '*.MYI' -exec $bin_du $duflags '{}' \; 2>&1 | $bin_awk '{ s += $1 } END { printf("%.0f\n", s) }')"
    fi

    if [ $((key_reads == 0)) -ne 0 ] ; then
        cecho "No key reads?!" boldred
        cecho "Seriously look into using some indexes" red
        key_cache_miss_rate="0"
        key_buffer_free="$(echo "$key_blocks_unused * $key_cache_block_size / $key_buffer_size * 100" | $bin_bc -l)"
        key_buffer_freeRND="$(echo "scale=0 ; $key_buffer_free / 1" | $bin_bc -l)"
    else
        key_cache_miss_rate="$((key_read_requests / $key_reads))"
        if [ ! -z "$key_blocks_unused" ] ; then
            key_buffer_free="$(echo "$key_blocks_unused * $key_cache_block_size / $key_buffer_size * 100" | $bin_bc -l)"
            key_buffer_freeRND="$(echo "scale=0 ; $key_buffer_free / 1" | $bin_bc -l)"
        else
            key_buffer_free="Unknown"
            key_buffer_freeRND="75"
        fi
    fi

    human_readable "$myisam_indexes" myisam_indexesHR
    cecho "Current MyISAM index space = $myisam_indexesHR $unit"

    human_readable "$key_buffer_size" key_buffer_sizeHR
    cecho "Current key_buffer_size = $key_buffer_sizeHR $unit"
    cecho "Key cache miss rate is 1 : $key_cache_miss_rate"
    cecho "Key buffer free ratio = $key_buffer_freeRND %"

    if [ $((key_cache_miss_rate <= 100)) -ne 0 ] && [ $((key_cache_miss_rate > 0)) -ne 0 ] && [ $((key_buffer_freeRND <= 20)) -ne 0 ] ; then
        cecho "You could increase key_buffer_size" boldred
        cecho "It is safe to raise this up to 1/4 of total system memory;"
        cecho "assuming this is a dedicated database server."
    elif [ $((key_buffer_freeRND <= 20)) -ne 0 ] && [ $((key_buffer_size <= $myisam_indexes)) -ne 0 ] ; then
        cecho "You could increase key_buffer_size" boldred
        cecho "It is safe to raise this up to 1/4 of total system memory;"
        cecho "assuming this is a dedicated database server."
    elif [ $((key_cache_miss_rate >= 10000)) -ne 0 ] || [ $((key_buffer_freeRND <= 50)) -ne 0 ] ; then
        cecho "Your key_buffer_size seems to be too high." red
        cecho "Perhaps you can use these resources elsewhere" red
    else
        cecho "Your key_buffer_size seems to be fine" green
    fi
}


check_query_cache ()
## -- Query Cache -- ##
{
    cecho "QUERY CACHE" boldblue

    mysql_status \'Qcache_free_memory\' qcache_free_memory
    mysql_status \'Qcache_total_blocks\' qcache_total_blocks
    mysql_status \'Qcache_free_blocks\' qcache_free_blocks
    mysql_status \'Qcache_lowmem_prunes\' qcache_lowmem_prunes
    mysql_variable \'version\' mysql_version
    mysql_variable \'query_cache_size\' query_cache_size
    mysql_variable \'query_cache_limit\' query_cache_limit
    mysql_variable \'query_cache_min_res_unit\' query_cache_min_res_unit

    if [ $((query_cache_size == 0)) -ne 0 ] ; then
        cecho "Query cache is supported but not enabled" red
        cecho "Perhaps you should set the query_cache_size" red
    else
        qcache_used_memory="$((query_cache_size - $qcache_free_memory))"
        qcache_mem_fill_ratio="$(echo "scale=2 ; $qcache_used_memory * 100 / $query_cache_size" | $bin_bc -l)"
        qcache_mem_fill_ratioHR="$(echo "scale=0 ; $qcache_mem_fill_ratio / 1" | $bin_bc -l)"

        cecho "Query cache is enabled" green
        human_readable "$query_cache_size" query_cache_sizeHR
        cecho "Current query_cache_size = $query_cache_sizeHR $unit"
        human_readable "$qcache_used_memory" qcache_used_memoryHR
        cecho "Current query_cache_used = $qcache_used_memoryHR $unit"
        human_readable "$query_cache_limit" query_cache_limitHR
        cecho "Current query_cache_limit = $query_cache_limitHR $unit"
        cecho "Current Query cache Memory fill ratio = $qcache_mem_fill_ratio %"
        human_readable "$query_cache_min_res_unit" query_cache_min_res_unitHR
        cecho "Current query_cache_min_res_unit = $query_cache_min_res_unitHR $unit"
        if [ $((qcache_free_blocks > 2)) -ne 0 ] && [ $((qcache_total_blocks > 0)) -ne 0 ] ; then
            qcache_percent_fragmented="$(echo "scale=2 ; $qcache_free_blocks * 100 / $qcache_total_blocks" | $bin_bc -l)"
            qcache_percent_fragmentedHR="$(echo "scale=0 ; $qcache_percent_fragmented / 1" | $bin_bc -l)"
            if [ $((qcache_percent_fragmentedHR > 20)) -ne 0 ] ; then
                cecho "Query Cache is $qcache_percent_fragmentedHR % fragmented" red
                cecho "Run \"FLUSH QUERY CACHE\" periodically to defragment the query cache memory" red
                cecho "If you have many small queries lower 'query_cache_min_res_unit' to reduce fragmentation." red
            fi
        fi

        if [ $((qcache_mem_fill_ratioHR <= 25)) -ne 0 ] ; then
            cecho "Your query_cache_size seems to be too high." red
            cecho "Perhaps you can use these resources elsewhere" red
        fi
        if [ $((qcache_lowmem_prunes >= 50)) -ne 0 ] && [ $((qcache_mem_fill_ratioHR >= 80)) -ne 0 ] ; then
            cechon "However, "
            cechon "$qcache_lowmem_prunes " boldred
            cecho "queries have been removed from the query cache due to lack of memory"
            cecho "Perhaps you should raise query_cache_size" boldred
        fi
        cecho "MySQL won't cache query results that are larger than query_cache_limit in size" yellow
    fi
}


check_sort_operations ()
## -- Sort Operations -- ##
{
    cecho "SORT OPERATIONS" boldblue

    mysql_status \'Sort_merge_passes\' sort_merge_passes
    mysql_status \'Sort_scan\' sort_scan
    mysql_status \'Sort_range\' sort_range
    mysql_variable \'sort_buffer_size\' sort_buffer_size
    mysql_variable \'read_rnd_buffer_size\' read_rnd_buffer_size

    total_sorts="$((sort_scan + $sort_range))"

    ## Correct for rounding error in mysqld where 512K != 524288 ##
    sort_buffer_size="$((sort_buffer_size + 8))"
    read_rnd_buffer_size="$((read_rnd_buffer_size + 8))"

    human_readable "$sort_buffer_size" sort_buffer_sizeHR
    cecho "Current sort_buffer_size = $sort_buffer_sizeHR $unit"

    human_readable "$read_rnd_buffer_size" read_rnd_buffer_sizeHR
    cechon "Current "
    cechon "read_rnd_buffer_size "
    cecho "= $read_rnd_buffer_sizeHR $unit"

    if [ $((total_sorts == 0)) -ne 0 ] ; then
        cecho "No sort operations have been performed"
        passes_per_sort="0"
    fi
    if [ $((sort_merge_passes != 0)) -ne 0 ] ; then
        passes_per_sort="$((sort_merge_passes / $total_sorts))"
    else
        passes_per_sort="0"
    fi

    if [ $((passes_per_sort >= 2)) -ne 0 ] ; then
        cechon "On average "
        cechon "$passes_per_sort " boldred
        cecho "sort merge passes are made per sort operation"
        cecho "You should raise your sort_buffer_size"
        cechon "You should also raise your "
        cecho "read_rnd_buffer_size"
    else
        cecho "Sort buffer seems to be fine" green
    fi
}


check_join_operations ()
## -- Joins -- ##
{
    cecho "JOINS" boldblue

    mysql_status \'Select_full_join\' select_full_join
    mysql_status \'Select_range_check\' select_range_check
    mysql_variable \'join_buffer_size\' join_buffer_size

    ## Some 4K is dropped from join_buffer_size adding it back to make sane ##
    ## handling of human-readable conversion ##
    join_buffer_size="$((join_buffer_size + 4096))"
    human_readable "$join_buffer_size" join_buffer_sizeHR 2

    cecho "Current join_buffer_size = $join_buffer_sizeHR $unit"
    cecho "You have had $select_full_join queries where a join could not use an index properly"

    if [ $((select_range_check == 0)) -ne 0 ] && [ $((select_full_join == 0)) -ne 0 ] ; then
        cecho "Your joins seem to be using indexes properly" green
    fi
    if [ $((select_full_join > 0)) -ne 0 ] ; then
        print_error="true"
        raise_buffer="true"
    fi
    if [ $((select_range_check > 0)) -ne 0 ] ; then
        cecho "You have had $select_range_check joins without keys that check for key usage after each row" red
        print_error="true"
        raise_buffer="true"
    fi

    if [ $((join_buffer_size >= 4194304)) -ne 0 ] ; then
        cecho "join_buffer_size >= 4 M" boldred
        cecho "This is not advised" boldred
    fi

    if [ "$print_error" = "true" ] ; then
        cecho "You should enable \"log-queries-not-using-indexes\""
        cecho "Then look for non indexed joins in the slow query log."
        if [ "$raise_buffer" = "yes" ] ; then
            cecho "If you are unable to optimize your queries you may want to increase your"
            cecho "join_buffer_size to accommodate larger joins in one pass."
            cecho " "
            cecho "Note! This script will still suggest raising the join_buffer_size when" boldred
            cecho "ANY joins not using indexes are found." boldred
        fi
    fi

    # XXX Add better tests for join_buffer_size pending mysql bug #15088 XXX #
}


check_tmp_tables ()
## -- Temp Tables -- ##
{
    cecho "TEMP TABLES" boldblue

    mysql_status \'Created_tmp_tables\' created_tmp_tables
    mysql_status \'Created_tmp_disk_tables\' created_tmp_disk_tables
    mysql_variable \'tmp_table_size\' tmp_table_size
    mysql_variable \'max_heap_table_size\' max_heap_table_size

    if [ $((created_tmp_tables == 0)) -ne 0 ] ; then
        tmp_disk_tables="0"
    else
        tmp_disk_tables="$((created_tmp_disk_tables * 100 / (created_tmp_tables + created_tmp_disk_tables)))"
    fi
    human_readable "$max_heap_table_size" max_heap_table_sizeHR
    cecho "Current max_heap_table_size = $max_heap_table_sizeHR $unit"

    human_readable "$tmp_table_size" tmp_table_sizeHR
    cecho "Current tmp_table_size = $tmp_table_sizeHR $unit"

    cecho "Of $created_tmp_tables temp tables, $tmp_disk_tables% were created on disk"
    if [ $((tmp_table_size > $max_heap_table_size)) -ne 0 ] ; then
        cecho "Effective in-memory tmp_table_size is limited to max_heap_table_size." yellow
    fi
    if [ $((tmp_disk_tables >= 25)) -ne 0 ] ; then
        cecho "Perhaps you should increase your tmp_table_size and/or max_heap_table_size" boldred
        cecho "to reduce the number of disk-based temporary tables" boldred
        cecho "Note! BLOB and TEXT columns are not allow in memory tables." yellow
        cecho "If you are using these columns raising these values might not impact your " yellow
        cecho "ratio of on disk temp tables." yellow
    else
        cecho "Created disk tmp tables ratio seems fine" green
    fi
}


check_open_files ()
## -- Open Files Limit -- ##
{
    cecho "OPEN FILES LIMIT" boldblue

    mysql_status \'Open_files\' open_files
    mysql_variable \'open_files_limit\' open_files_limit

    if [ -z "$open_files_limit" ] || [ $((open_files_limit == 0)) -ne 0 ] ; then
        open_files_limit="$(ulimit -n)"
        cant_override="1"
    else
        cant_override="0"
    fi
    cecho "Current open_files_limit = $open_files_limit files"

    open_files_ratio="$((open_files * 100 / $open_files_limit))"

    cecho "The open_files_limit should typically be set to at least 2x-3x" yellow
    cecho "that of table_open_cache if you have heavy MyISAM usage." yellow
    if [ $((open_files_ratio >= 75)) -ne 0 ] ; then
        cecho "You currently have open more than 75% of your open_files_limit" boldred
        if [ $((cant_override == 1)) -ne 0 ] ; then
            cecho "You should set a higer value for ulimit -u in the mysql startup script then restart mysqld" boldred
        elif [ $((cant_override == 0)) -ne 0 ] ; then
            cecho "You should set a higher value for open_files_limit in my.cnf" boldred
        else
            cecho "ERROR can't determine if mysqld override of ulimit is allowed" boldred
            exit 1
        fi
    else
        cecho "Your open_files_limit value seems to be fine" green
    fi
}


check_table_cache ()
## -- Table Cache -- ##
{
    cecho "TABLE CACHE" boldblue

    mysql_status \'Open_tables\' open_tables
    mysql_status \'Opened_tables\' opened_tables
    mysql_status \'Open_table_definitions\' open_table_definitions
    mysql_variable \'datadir\' datadir
    mysql_variable \'table_open_cache\' table_open_cache
    mysql_variable \'table_definition_cache\' table_definition_cache

    table_count="$($cmd_mysql -Bse "/*!50000 SELECT COUNT(*) FROM information_schema.tables WHERE TABLE_TYPE='BASE TABLE' */")"

    if [ -z "$table_count" ] ; then
        if [ "$UID" != "$socket_owner" ] && [ "$UID" != "0" ] ; then
            cecho "You are not '$socket_owner' or 'root'" red
            cecho "I am unable to determine the table_count!" red
        else
            table_count="$($bin_find $datadir 2>&1 | $bin_grep -ic .frm$)"
        fi
    fi

    if [ $((opened_tables != 0)) -ne 0 ] && [ $((table_open_cache != 0)) -ne 0 ] ; then
        table_cache_hit_rate="$((open_tables * 100 / $opened_tables))"
        table_cache_fill="$((open_tables * 100 / $table_open_cache))"
    elif [ $((opened_tables == 0)) -ne 0 ] && [ $((table_open_cache != 0)) -ne 0 ] ; then
        table_cache_hit_rate="100"
        table_cache_fill="$((open_tables * 100 / $table_open_cache))"
    else
        cecho "ERROR no table_open_cache?!" boldred
        exit 1
    fi
    cecho "Current table_open_cache = $table_open_cache tables"
    cecho "Current table_definition_cache = $table_definition_cache tables"
    if [ ! -z "$table_count" ] ; then
        cecho "You have a total of $table_count tables"
    fi

    if [ $((table_cache_fill < 95)) -ne 0 ] ; then
        cechon "You have "
        cechon "$open_tables " green
        cecho "open tables."
        cecho "The table_open_cache value seems to be fine" green
    elif [ $((table_cache_hit_rate <= 85)) -ne 0 ] || [ $((table_cache_fill >= 95)) -ne 0 ] ; then
        cechon "You have "
        cechon "$open_tables " boldred
        cecho "open tables."
        cechon "Current table_open_cache hit rate is "
        cecho "$table_cache_hit_rate%" boldred
        cechon ", while "
        cechon "$table_cache_fill% " boldred
        cecho "of your table cache is in use"
        cecho "You should probably increase your table_open_cache" red
    else
        cechon "Current table_open_cache hit rate is "
        cechon "$table_cache_hit_rate%" green
        cechon ", while "
        cechon "$table_cache_fill% " green
        cecho "of your table cache is in use"
        cecho "The table cache value seems to be fine" green
    fi
    if [ $((table_definition_cache <= $table_count)) -ne 0 ] && [ $((table_count >= 100)) -ne 0 ] ; then
        cecho "You should probably increase your table_definition_cache value." red
    fi
}


check_table_locking ()
## -- Table Locking -- ##
{
    cecho "TABLE LOCKING" boldblue

    mysql_status \'Table_locks_waited\' table_locks_waited
    mysql_status \'Table_locks_immediate\' table_locks_immediate
    mysql_variable \'concurrent_insert\' concurrent_insert
    mysql_variable \'low_priority_updates\' low_priority_updates

    if [ "$concurrent_insert" = "ON" ] ; then
        concurrent_insert="1"
    elif [ "$concurrent_insert" = "OFF" ] ; then
        concurrent_insert="0"
    fi

    cechon "Current Lock Wait ratio = "
    if [ $((table_locks_waited > 0)) -ne 0 ] ; then
        immediate_locks_miss_rate="$((table_locks_immediate / $table_locks_waited))"
        cecho "1 : $immediate_locks_miss_rate" red
    else
        immediate_locks_miss_rate="99999" # perfect
        cecho "0 : $questions"
    fi
    if [ $((immediate_locks_miss_rate < 5000)) -ne 0 ] ; then
        cecho "You may benefit from selective use of InnoDB."
        if [ "$low_priority_updates" = "OFF" ] ; then
            cecho "If you have long running SELECT's against MyISAM tables and perform"
            cecho "frequent updates consider setting 'low_priority_updates=1'"
        fi
        if [ "$concurrent_insert" = "AUTO" ] || [ "$concurrent_insert" = "NEVER" ] ; then
            cecho "If you have a high concurrency of inserts on Dynamic row-length tables"
            cecho "consider setting 'concurrent_insert=ALWAYS'."
        fi
    else
        cecho "Your table locking seems to be fine" green
    fi
}


check_table_scans ()
## -- Table Scans -- ##
{
    cecho "TABLE SCANS" boldblue

    mysql_status \'Com_select\' com_select
    mysql_status \'Handler_read_rnd_next\' read_rnd_next
    mysql_variable \'read_buffer_size\' read_buffer_size

    human_readable "$read_buffer_size" read_buffer_sizeHR
    cecho "Current read_buffer_size = $read_buffer_sizeHR $unit"

    if [ $((com_select > 0)) -ne 0 ] ; then
        full_table_scans="$((read_rnd_next / $com_select))"
        cecho "Current table scan ratio = $full_table_scans : 1"
        if [ $((full_table_scans >= 4000)) -ne 0 ] && [ $((read_buffer_size <= 2097152)) -ne 0 ] ; then
            cecho "You have a high ratio of sequential access requests to SELECTs" red
            cechon "You may benefit from raising " red
            cechon "read_buffer_size " red
            cecho "and/or improving your use of indexes." red
        elif [ $((read_buffer_size > 8388608)) -ne 0 ] ; then
            cechon "read_buffer_size is over 8 MB " red
            cecho "there is probably no need for such a large read_buffer" red

        else
            cecho "read_buffer_size seems to be fine" green
        fi
    else
        cecho "read_buffer_size seems to be fine" green
    fi
}


check_innodb_status ()
## -- InnoDB -- ##
{
    ## See http://bugs.mysql.com/59393

    if [ $((mysql_version_num < 050603)) -ne 0 ] ; then
        mysql_variable \'have_innodb\' have_innodb
    fi
    if [ $((mysql_version_num >= 050500)) -ne 0 ] && [ $((mysql_version_num < 050512)) -ne 0 ] ; then
        mysql_variable \'ignore_builtin_innodb\' ignore_builtin_innodb
        if [ "$ignore_builtin_innodb" = "ON" ] || [ "$have_innodb" = "NO" ] ; then
            innodb_enabled="0"
        else
            innodb_enabled="1"
        fi
    elif [ "$major_version" = "5.5" ] && [ $((mysql_version_num >= 050512)) -ne 0 ] ; then
        mysql_variable \'ignore_builtin_innodb\' ignore_builtin_innodb
        if [ "$ignore_builtin_innodb" = "ON" ] ; then
            innodb_enabled="0"
        else
            innodb_enabled="1"
        fi
    elif [ $((mysql_version_num >= 050600)) -ne 0 ] && [ $((mysql_version_num < 050603)) -ne 0 ] ; then
        mysql_variable \'ignore_builtin_innodb\' ignore_builtin_innodb
        if [ "$ignore_builtin_innodb" = "ON" ] || [ "$have_innodb" = "NO" ] ; then
            innodb_enabled="0"
        else
            innodb_enabled="1"
        fi
    elif [ "$major_version" = "5.6" ] && [ $((mysql_version_num >= 050603)) -ne 0 ] ; then
        mysql_variable \'ignore_builtin_innodb\' ignore_builtin_innodb
        if [ "$ignore_builtin_innodb" = "ON" ] ; then
            innodb_enabled="0"
        else
            innodb_enabled="1"
        fi
    elif [ $((mysql_version_num >= 050700)) -ne 0 ] ; then
        mysql_variable \'ignore_builtin_innodb\' ignore_builtin_innodb
        if [ "$ignore_builtin_innodb" = "ON" ] ; then
            innodb_enabled="0"
        else
            innodb_enabled="1"
        fi
    fi
    if [ $((innodb_enabled == 1)) -ne 0 ] ; then
        cecho "INNODB STATUS" boldblue

        mysql_status \'Innodb_buffer_pool_pages_data\' innodb_buffer_pool_pages_data
        mysql_status \'Innodb_buffer_pool_pages_misc\' innodb_buffer_pool_pages_misc
        mysql_status \'Innodb_buffer_pool_pages_free\' innodb_buffer_pool_pages_free
        mysql_status \'Innodb_buffer_pool_pages_total\' innodb_buffer_pool_pages_total
        mysql_status \'Innodb_buffer_pool_read_ahead_seq\' innodb_buffer_pool_read_ahead_seq
        mysql_status \'Innodb_buffer_pool_read_requests\' innodb_buffer_pool_read_requests
        mysql_status \'Innodb_os_log_pending_fsyncs\' innodb_os_log_pending_fsyncs
        mysql_status \'Innodb_os_log_pending_writes\' innodb_os_log_pending_writes
        mysql_status \'Innodb_log_waits\' innodb_log_waits
        mysql_status \'Innodb_row_lock_time\' innodb_row_lock_time
        mysql_status \'Innodb_row_lock_waits\' innodb_row_lock_waits
        mysql_variable \'innodb_buffer_pool_size\' innodb_buffer_pool_size
        mysql_variable \'innodb_additional_mem_pool_size\' innodb_additional_mem_pool_size
        mysql_variable \'innodb_fast_shutdown\' innodb_fast_shutdown
        mysql_variable \'innodb_flush_log_at_trx_commit\' innodb_flush_log_at_trx_commit
        mysql_variable \'innodb_locks_unsafe_for_binlog\' innodb_locks_unsafe_for_binlog
        mysql_variable \'innodb_log_buffer_size\' innodb_log_buffer_size
        mysql_variable \'innodb_log_file_size\' innodb_log_file_size
        mysql_variable \'innodb_log_files_in_group\' innodb_log_files_in_group
        mysql_variable \'innodb_safe_binlog\' innodb_safe_binlog
        mysql_variable \'innodb_thread_concurrency\' innodb_thread_concurrency

        innodb_indexes="$($cmd_mysql -Bse "/*!50000 SELECT IFNULL(SUM(INDEX_LENGTH),0) FROM information_schema.tables WHERE ENGINE='InnoDB' */")"
        innodb_data="$($cmd_mysql -Bse "/*!50000 SELECT IFNULL(SUM(DATA_LENGTH),0) FROM information_schema.tables WHERE ENGINE='InnoDB' */")"

        human_readable "$innodb_indexes" innodb_indexesHR
        cecho "Current InnoDB index space = $innodb_indexesHR $unit"
        human_readable "$innodb_data" innodb_dataHR
        cecho "Current InnoDB data space = $innodb_dataHR $unit"
        percent_innodb_buffer_pool_free="$((innodb_buffer_pool_pages_free * 100 / $innodb_buffer_pool_pages_total))"
        cecho "Current InnoDB buffer pool free = "$percent_innodb_buffer_pool_free" %"
        human_readable "$innodb_buffer_pool_size" innodb_buffer_pool_sizeHR
        cecho "Current innodb_buffer_pool_size = $innodb_buffer_pool_sizeHR $unit"
        cecho "Depending on how much space your innodb indexes take up it may be safe"
        cecho "to increase this value to up to 2 / 3 of total system memory"
    else
        cecho "No InnoDB Support Enabled!" boldred
    fi
}


total_memory_used ()
## -- Total Memory Usage -- ##
{
    cecho "MEMORY USAGE" boldblue

    mysql_status \'Max_used_connections\' max_used_connections
    mysql_variable \'read_buffer_size\' read_buffer_size
    mysql_variable \'read_rnd_buffer_size\' read_rnd_buffer_size
    mysql_variable \'sort_buffer_size\' sort_buffer_size
    mysql_variable \'thread_stack\' thread_stack
    mysql_variable \'max_connections\' max_connections
    mysql_variable \'join_buffer_size\' join_buffer_size
    mysql_variable \'tmp_table_size\' tmp_table_size
    mysql_variable \'max_heap_table_size\' max_heap_table_size
    mysql_variable \'log_bin\' log_bin

    if [ "$log_bin" = "ON" ] ; then
        mysql_variable \'binlog_cache_size\' binlog_cache_size
    else
        binlog_cache_size="0"
    fi

    if [ $((max_heap_table_size <= $tmp_table_size)) -ne 0 ] ; then
        effective_tmp_table_size="$max_heap_table_size"
    else
        effective_tmp_table_size="$tmp_table_size"
    fi

    per_thread_buffers="$(echo "($read_buffer_size + $read_rnd_buffer_size + $sort_buffer_size + $thread_stack + $join_buffer_size + $binlog_cache_size) * $max_connections" | $bin_bc -l)"
    per_thread_max_buffers="$(echo "($read_buffer_size + $read_rnd_buffer_size + $sort_buffer_size + $thread_stack + $join_buffer_size + $binlog_cache_size) * $max_used_connections" | $bin_bc -l)"

    mysql_variable \'innodb_buffer_pool_size\' innodb_buffer_pool_size
    if [ -z "$innodb_buffer_pool_size" ] ; then
        innodb_buffer_pool_size="0"
    fi

    mysql_variable \'innodb_additional_mem_pool_size\' innodb_additional_mem_pool_size
    if [ -z "$innodb_additional_mem_pool_size" ] ; then
        innodb_additional_mem_pool_size="0"
    fi

    mysql_variable \'innodb_log_buffer_size\' innodb_log_buffer_size
    if [ -z "$innodb_log_buffer_size" ] ; then
        innodb_log_buffer_size="0"
    fi

    mysql_variable \'key_buffer_size\' key_buffer_size
    if [ -z "$key_buffer_size" ] ; then
        key_buffer_size="0"
    fi

    mysql_variable \'query_cache_size\' query_cache_size
    if [ -z "$query_cache_size" ] ; then
        query_cache_size="0"
    fi

    global_buffers="$(echo "$innodb_buffer_pool_size + $innodb_additional_mem_pool_size + $innodb_log_buffer_size + $key_buffer_size + $query_cache_size" | $bin_bc -l)"

    max_memory="$(echo "$global_buffers + $per_thread_max_buffers" | $bin_bc -l)"
    total_memory="$(echo "$global_buffers + $per_thread_buffers" | $bin_bc -l)"

    pct_of_sys_mem="$(echo "scale=0 ; $total_memory * 100 / $physical_memory" | $bin_bc -l)"

    if [ $((pct_of_sys_mem > 90)) -ne 0 ] ; then
        txt_color="boldred"
        error="1"
    else
        txt_color=
        error="0"
    fi

    human_readable "$max_memory" max_memoryHR
    cecho "Max Memory Ever Allocated : $max_memoryHR $unit" $txt_color
    human_readable "$per_thread_buffers" per_thread_buffersHR
    cecho "Configured Max Per-thread Buffers : $per_thread_buffersHR $unit" $txt_color
    human_readable "$global_buffers" global_buffersHR
    cecho "Configured Max Global Buffers : $global_buffersHR $unit" $txt_color
    human_readable "$total_memory" total_memoryHR
    cecho "Configured Max Memory Limit : $total_memoryHR $unit" $txt_color
    human_readable "$effective_tmp_table_size" effective_tmp_table_sizeHR
    cecho "Plus $effective_tmp_table_sizeHR $unit per temporary table created"
    human_readable "$physical_memory" physical_memoryHR
    cecho "Physical Memory : $physical_memoryHR $unit" $txt_color
    if [ $((error == 1)) -ne 0 ] ; then
        cecho " "
        cecho "Max memory limit exceeds 90% of physical memory" $txt_color
    else
        cecho "Max memory limit seem to be within acceptable norms" green
    fi
    unset txt_color
}


login_validation ()
## --    -- ##
{
    check_for_socket
    check_mysql_login
}


shared_info ()
## --    -- ##
{
    mysql_status \'Questions\' questions
    socket_owner="$($bin_ls -lnH $socket | $bin_awk '{ print $3 }')"
    export major_version="$($cmd_mysql -Bse "SELECT SUBSTRING_INDEX(VERSION(), '.', +2)")"
    export mysql_version_num="$($cmd_mysql -Bse "SELECT VERSION()" | $bin_awk -F \. '{ printf "%2d", $1; printf "%02d", $2; printf "%02d", $3 }')"
    if [ $((mysql_version_num < 050500)) -ne 0 ] ; then
        cecho "UNSUPPORTED MYSQL VERSION" boldred
        exit 1
    fi
}


get_system_info ()
## --    -- ##
{
    export OS="$($bin_uname)"

    # Get information for various UNIXes
    if [ "$OS" = "Darwin" ] ; then
        ps_socket="$($bin_netstat -ln | $bin_awk '/mysql(.*)?\.sock/ { print $9 }' | $bin_head -n 1)"
        found_socks="$($bin_netstat -ln | $bin_awk '/mysql(.*)?\.sock/ { print $9 }')"
        export physical_memory="$($bin_sysctl -n hw.memsize)"
        export duflags=''
    elif [ "$OS" = "FreeBSD" ] || [ "$OS" = "OpenBSD" ] ; then
        ## On FreeBSD must be root to locate sockets.
        ps_socket="$($bin_netstat -ln | $bin_awk '/mysql(.*)?\.sock/ { print $9 }' | $bin_head -n 1)"
        found_socks="$($bin_netstat -ln | $bin_awk '/mysql(.*)?\.sock/ { print $9 }')"
        export physical_memory="$($bin_sysctl -n hw.realmem)"
        export duflags=""
    elif [ "$OS" = "Linux" ] ; then
        ps_socket="$($bin_netstat -ln | $bin_awk '/mysql(.*)?\.sock/ { print $9 }' | $bin_head -n 1)"
        found_socks="$($bin_netstat -ln | $bin_awk '/mysql(.*)?\.sock/ { print $9 }')"
        export physical_memory="$($bin_awk '/^MemTotal/ { printf("%.0f", $2*1024) }' < /proc/meminfo)"
        export duflags="-b"
    elif [ "$OS" = "SunOS" ] ; then
        ps_socket="$($bin_netstat -an | $bin_awk '/mysql(.*)?.sock/ { print $5 }' | $bin_head -n 1)"
        found_socks="$($bin_netstat -an | $bin_awk '/mysql(.*)?.sock/ { print $5 }')"
        if [ -z "$(which prtconf)" ] ; then
            cecho "Error: Needed command \"prtconf\" not found in PATH!"
            exit 1
        else
            bin_path="$(which prtconf)"
            export bin_prtconf="$bin_path"
        fi
        export physical_memory="$($bin_prtconf | $bin_awk '/^Memory\ size:/ { print $3*1048576 }')"
    fi
}


banner_info ()
## --    -- ##
{
    shared_info
    print_banner            ; cecho " "
    check_mysql_version     ; cecho " "
    post_uptime_warning     ; cecho " "
}


misc ()
## --    -- ##
{
    shared_info
    check_slow_queries      ; cecho " "
    check_binary_log        ; cecho " "
    check_threads           ; cecho " "
    check_used_connections    ; cecho " "
    check_innodb_status     ; cecho " "
}


memory ()
## --    -- ##
{
    shared_info
    total_memory_used       ; cecho " "
    check_key_buffer_size    ; cecho " "
    check_query_cache       ; cecho " "
    check_sort_operations    ; cecho " "
    check_join_operations    ; cecho " "
}


file ()
## --    -- ##
{
    shared_info
    check_open_files        ; cecho " "
    check_table_cache       ; cecho " "
    check_tmp_tables        ; cecho " "
    check_table_scans       ; cecho " "
    check_table_locking     ; cecho " "
}


all ()
## --    -- ##
{
    banner_info
    misc
    memory
    file
}


prompt ()
## --    -- ##
{
    prompted="true"
    read -p "Username [anonymous] : " user
    read -rp "Password [<none>] : " pass
    cecho " "
    read -p "Socket [/var/lib/mysql/mysql.sock] : " socket
    if [ -z "$socket" ] ; then
        export socket="/var/lib/mysql/mysql.sock"
    fi

    if [ -z "$pass" ] ; then
        export cmd_mysql="$bin_mysql -S $socket -u$user"
        export cmd_mysqladmin="$bin_mysqladmin -S $socket -u$user"
    else
        export cmd_mysql="$bin_mysql -S $socket -u$user -p$pass"
        export cmd_mysqladmin="$bin_mysqladmin -S $socket -u$user -p$pass"
    fi

    login_validation

    if [ "$?" = "1" ] ; then
        exit 1
    fi

    read -p "Mode to test - banner, file, misc, mem, innodb, [all] : " REPLY
    if [ -z "$REPLY" ] ; then
        REPLY="all"
    fi
    case "$REPLY" in
        banner | BANNER | header | HEADER | head | HEAD)
            banner_info
        ;;
        misc | MISC | miscelaneous )
            misc
        ;;
        mem | memory |    MEM | MEMORY )
            memory
        ;;
        file | FILE | disk | DISK )
            file
        ;;
        innodb | INNODB )
            innodb
        ;;
        all | ALL )
            all
        ;;
        * )
            cecho "Invalid Mode! Valid options are 'banner', 'misc', 'memory', 'file', 'innodb' or 'all'" boldred
            exit 1
        ;;
    esac
}


main ()
## --    -- ##
{
    local var1="$1"

    get_system_info

    if [ -z "$var1" ] ; then
        login_validation
        mode="ALL"
    elif [ "$var1" = "prompt" ] || [ "$var1" = "PROMPT" ] ; then
        mode="$var1"
    elif [ "$var1" != "prompt" ] || [ "$var1" != "PROMPT" ] ; then
        login_validation
        mode="$var1"
    fi

    case "$mode" in
        all | ALL )
            all
        ;;
        mem | memory |    MEM | MEMORY )
            banner_info
            memory
        ;;
        file | FILE | disk | DISK )
            banner_info
            file
        ;;
        banner | BANNER | header | HEADER | head | HEAD )
            banner_info
        ;;
        misc | MISC | miscelaneous )
            banner_info
            misc
        ;;
        innodb | INNODB )
            banner_info
            check_innodb_status
        ;;
        prompt | PROMPT )
            prompt
        ;;
        *)
            cecho "usage: $0 [ all | banner | file | innodb | memory | misc | prompt ]" boldred
            exit 1
        ;;
    esac
}

if [ ! -z "$2" ] ; then
    main usage
elif [ ! -z "$1" ] ; then
    main "$1"
else
    main all
fi
