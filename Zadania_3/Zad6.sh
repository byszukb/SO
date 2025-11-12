#!/bin/bash

process_tasks() {
    # Walidacja argumentów
    if [ $# -ne 2 ]; then
        echo "Blad: Oczekiwano 2 argumentow" >&2
        return 1
    fi
    
    # Sprawdzenie czy argumenty są liczbami
    if ! [[ "$1" =~ ^[0-9]+$ ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "Blad: Argumenty musza byc liczbami" >&2
        return 1
    fi
    
    local num_tasks=$1
    local num_workers=$2
    
    # Walidacja zakresów
    if [ "$num_tasks" -lt 1 ]; then
        echo "Blad: Liczba zadan musi byc >= 1" >&2
        return 1
    fi
    
    if [ "$num_workers" -lt 1 ] || [ "$num_workers" -gt 5 ]; then
        echo "Blad: Liczba workerow musi byc 1-5" >&2
        return 1
    fi
    
    # Tworzenie katalogu tymczasowego
    local tmpdir=$(mktemp -d)
    local producer_c="$tmpdir/producer.c"
    local producer_bin="$tmpdir/producer"
    local worker_py="$tmpdir/worker.py"
    local fifo_tasks="$tmpdir/fifo_tasks"
    local results_file="$tmpdir/results.txt"
    
    # Funkcja czyszcząca
    cleanup() {
        # Usunięcie potoków
        for ((i=0; i<num_workers; i++)); do
            rm -f "$tmpdir/fifo_w$i" "$tmpdir/fifo_r$i"
        done
        rm -f "$fifo_tasks" "$results_file"
        
        # Usunięcie plików
        rm -f "$producer_c" "$producer_bin" "$worker_py"
        rmdir "$tmpdir" 2>/dev/null
    }
    trap cleanup EXIT
    
    # Tworzenie kodu C producenta
    cat > "$producer_c" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int main(int argc, char *argv[]) {
    if (argc != 2) return 1;
    int n = atoi(argv[1]);
    srand(time(NULL));
    
    for (int i = 0; i < n; i++) {
        int num = 100 + rand() % 901;
        printf("%d\n", num);
        fflush(stdout);
    }
    return 0;
}
EOF
    
    # Kompilacja producenta
    gcc -o "$producer_bin" "$producer_c" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "Blad: Nie udalo sie skompilowac producenta" >&2
        return 1
    fi
    
    # Tworzenie kodu Python workera
    cat > "$worker_py" << 'EOF'
import sys

def is_prime(n):
    if n < 2:
        return False
    for i in range(2, int(n**0.5) + 1):
        if n % i == 0:
            return False
    return True

worker_id = int(sys.argv[1])

while True:
    line = sys.stdin.readline().strip()
    if not line or line == '-1':
        break
    
    num = int(line)
    result = 'TAK' if is_prime(num) else 'NIE'
    print(f'{num} {result} {worker_id}', flush=True)
EOF
    
    # Tworzenie potoków
    mkfifo "$fifo_tasks"
    for ((i=0; i<num_workers; i++)); do
        mkfifo "$tmpdir/fifo_w$i"
        mkfifo "$tmpdir/fifo_r$i"
    done
    
    # Start pomiaru czasu
    local start_time=$SECONDS
    
    # Uruchomienie producenta w tle
    "$producer_bin" "$num_tasks" > "$fifo_tasks" &
    local producer_pid=$!
    
    # Uruchomienie workerów w tle - każdy zapisuje do swojego potoku
    local worker_pids=()
    for ((i=0; i<num_workers; i++)); do
        (python3 "$worker_py" "$i" < "$tmpdir/fifo_w$i" > "$tmpdir/fifo_r$i") &
        worker_pids+=($!)
    done
    
    # Proces zbierający wyniki od wszystkich workerów do pliku
    (
        for ((i=0; i<num_workers; i++)); do
            (
                while IFS= read -r line; do
                    echo "$line"
                done < "$tmpdir/fifo_r$i"
            ) &
        done
        wait
    ) > "$results_file" &
    local collector_pid=$!
    
    # Proces rozdzielający zadania round-robin
    (
        local worker_idx=0
        exec 3< "$fifo_tasks"
        
        # Otwieramy deskryptory do wszystkich workerów
        for ((i=0; i<num_workers; i++)); do
            eval "exec $((10+i))>$tmpdir/fifo_w$i"
        done
        
        while IFS= read -r task <&3; do
            local fd=$((10 + worker_idx))
            echo "$task" >&$fd
            worker_idx=$(( (worker_idx + 1) % num_workers ))
        done
        
        # Zamykamy wejście
        exec 3<&-
        
        # Wysyłamy sygnał zakończenia do wszystkich workerów
        for ((i=0; i<num_workers; i++)); do
            local fd=$((10+i))
            echo "-1" >&$fd
            eval "exec $((10+i))>&-"
        done
    ) &
    local distributor_pid=$!
    
    # Czekamy na zakończenie producenta i dystrybutora
    wait $producer_pid 2>/dev/null
    wait $distributor_pid 2>/dev/null
    
    # Czekamy na zakończenie workerów
    for pid in "${worker_pids[@]}"; do
        wait $pid 2>/dev/null
    done
    
    # Czekamy na zebranie wszystkich wyników
    wait $collector_pid 2>/dev/null
    
    # Wyświetlamy wyniki
    local task_counter=0
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            read num result worker <<< "$line"
            echo "Zadanie $num: wynik $result (worker $worker)"
            ((task_counter++))
        fi
    done < "$results_file"
    
    # Obliczenie czasu wykonania
    local end_time=$SECONDS
    local elapsed=$(printf "%.2f" $(echo "scale=2; $end_time - $start_time" | bc))
    
    echo "Przetworzono $task_counter zadan w $elapsed sekund"
}

# Wywołanie funkcji z argumentami skryptu
process_tasks "$@"