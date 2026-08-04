1. 读取本项目，增加顶部 net 模式的 IP 追踪，让用户能够看到哪些 IP 流量如何，调用 nettop 即可
2. 继续调整 build.sh，增加发布 imonitor 到 brew 和推送 github 的逻辑
3. 继续检查 imonitor 详情中没有显示 app 链接的远端IP 地址的问题，这里需要支持 ipv4/ipv6 的显示，需要能明确的指导 app 是连接到了什么 IP
