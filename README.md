### Snapdragon 8 gen3

| CPU | `taskset` 마스크 | 타입       | 코어        | 최대 주파수 | `cpu_capacity` |
| --- | ------------------ | ---------- | ----------- | ----------- | ---------------- |
| 0   | `1`              | little     | Cortex-A520 | 2.27GHz     | 379              |
| 1   | `2`              | little     | Cortex-A520 | 2.27GHz     | 379              |
| 2   | `4`              | mid        | Cortex-A720 | 3.15GHz     | 923              |
| 3   | `8`              | mid        | Cortex-A720 | 3.15GHz     | 923              |
| 4   | `10`             | mid        | Cortex-A720 | 3.15GHz     | 923              |
| 5   | `20`             | mid        | Cortex-A720 | 2.96GHz     | 867              |
| 6   | `40`             | mid        | Cortex-A720 | 2.96GHz     | 867              |
| 7   | `80`             | big(prime) | Cortex-X4   | 3.30GHz     | 1024             |

### step1. 코어를 바꿨을때 실행시간이 다른가?

설정: 

1. npu에 풀로 위임 (inception v3 1개 (cpu 2~4에 대해서만))

2. 추론횟수: 1,000,000회 (백만회)

[결과]]

0. 돌리기전 ambient temp가 어떻게 되었는지? (32~34도를 맞추는중)
1. cpu최고온도 (몇분돌렸을때?) => (DTM) freq가 내려가는가?
2. npu최고온도 (몇분돌렸을때?) ⇒ (DTM) 실행시간이 느려지는가?

cpu2실험시 amb

TB321FU:/data/local/tmp/SM # cd code/motivation/
$(cat $z/type); case $t in cpu*) echo "$(basename $z) $t $(cat $z/temp)";; esac; done                                         <
thermal_zone10 cpuss-0 32300
thermal_zone11 cpuss-1 31500
thermal_zone12 cpuss-2 31900
thermal_zone13 cpuss-3 32300
thermal_zone14 cpu-2-0-0 31900
thermal_zone15 cpu-2-0-1 31500
thermal_zone16 cpu-2-1-0 31900
thermal_zone17 cpu-2-1-1 31900
thermal_zone18 cpu-2-2-0 31900
thermal_zone19 cpu-2-2-1 32300
thermal_zone20 cpu-1-0-0 32300
thermal_zone21 cpu-1-0-1 31900
thermal_zone22 cpu-1-1-0 31900
thermal_zone23 cpu-1-1-1 31900
thermal_zone25 cpu-1-2-0 34200
thermal_zone26 cpu-1-2-1 34600
thermal_zone27 cpu-1-2-2 34600
thermal_zone28 cpu-0-0-0 34900
thermal_zone29 cpu-0-1-0 34600
