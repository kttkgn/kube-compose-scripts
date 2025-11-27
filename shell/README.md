
<img width="1842" height="522" alt="image" src="https://github.com/user-attachments/assets/d4ac059d-6b35-45bf-bedc-9937233cfbd1" />


### perf_monitor
```shell
chmod +x perf_monitor.sh
```
```shell
# CentOS/RHEL
yum install -y ifstat bc iproute2

# Ubuntu/Debian
apt install -y ifstat bc iproute2

# MacOS（需先装brew）
brew install ifstat bc
```
基础使用
```shell
./perf_monitor.sh
```
指定时长 + 输出文件 + 自定义磁盘分区
```shell
./perf_monitor.sh --duration 60 --interval 3 --output /tmp/perf.log --disk /data
```
后台运行
```shell
./perf_monitor.sh --duration 300 --interval 5 --daemon --interface ens33
```
查看帮助信息
```shell
./perf_monitor.sh --help
```
