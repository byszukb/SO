#!/bin/bash

bash_python_communication() {
    if [ $# -ne 1 ]; then
        echo "Blad: Oczekiwano 1 argumentu" >&2
        return 1
    fi
    
    if [ ! -f "$1" ]; then
        echo "Blad: Plik nie istnieje" >&2
        return 1
    fi
    
    if [ ! -s "$1" ]; then
        echo "Blad: Plik jest pusty" >&2
        return 1
    fi
    
    plik="$1"
    fifo_in="/tmp/fifo_in_$$"
    fifo_out="/tmp/fifo_out_$$"
    
    mkfifo "$fifo_in"
    mkfifo "$fifo_out"
    
    python3 -c "
fifo_in = open('$fifo_in', 'r')
fifo_out = open('$fifo_out', 'w')

total_words = 0
total_chars = 0

while True:
    line = fifo_in.readline().strip()
    if line == 'EOF':
        fifo_out.write(f'DONE {total_words} {total_chars}\n')
        fifo_out.flush()
        break
    
    words = len(line.split())
    chars = len(line)
    total_words += words
    total_chars += chars
    
    fifo_out.write(f'{words} {chars}\n')
    fifo_out.flush()

fifo_in.close()
fifo_out.close()
" &
    
    python_pid=$!
    
    exec 3> "$fifo_in"
    exec 4< "$fifo_out"
    
    numer_linii=1
    
    while IFS= read -r linia; do
        echo "$linia" >&3
        
        read -u 4 slowa znaki
        echo "Linia $numer_linii: $slowa slow, $znaki znakow"
        
        numer_linii=$((numer_linii + 1))
    done < "$plik"
    
    echo "EOF" >&3
    
    read -u 4 status total_words total_chars
    
    echo "Podsumowanie: $total_words slow, $total_chars znakow"
    
    exec 3>&-
    exec 4<&-
    
    wait $python_pid
    
    rm -f "$fifo_in" "$fifo_out"
}

bash_python_communication "$@"

