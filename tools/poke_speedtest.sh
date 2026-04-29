#!/bin/bash
# POKE speedtest.prg into C64 memory via keyboard (mbc raw_seq)
# Comma = :33 (hex keycode), Enter = O

/media/fat/linux/mbc raw_seq "poke2049:3310O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2050:338O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2051:3310O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2052:330O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2053:3384O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2054:33178O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2055:3384O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2056:3373O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2057:330O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2058:3327O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2059:338O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2060:3320O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2061:330O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2062:33129O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2063:3373O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2064:33178O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2065:3349O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2066:33164O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2067:3349O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2068:3348O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2069:3348O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2070:3348O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2071:3348O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2072:3358O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2073:33130O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2074:330O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2075:3337O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2076:338O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2077:3330O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2078:330O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2079:33153O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2080:3384O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2081:3373O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2082:33171O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2083:3384O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2084:330O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2085:3345O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2086:338O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2087:3340O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2088:330O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2089:33137O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2090:3349O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2091:3348O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2092:330O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2093:330O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke2094:330O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke45:3347O"
sleep 0.5
/media/fat/linux/mbc raw_seq "poke46:338O"
sleep 0.5

# RUN the program
/media/fat/linux/mbc raw_seq "runO"
echo "Done - 46 POKEs + 2 pointer POKEs sent"
