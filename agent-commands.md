
Agent Commands all start from this point forward with a new minicube cluster:

```bash
kubectl port-forward svc/vllm-service 8000:8000 &
```

Next the following sample commands I am using to get my Telegram chat started:

```bash


/bash cd DesktopShare && git pull

/bash source .env && nohup sh ./DesktopShare/files/agent-install-operators.sh > deploy.log 2>&1 &

# notice use of -windows yaml for nifi
/bash source .env && cd ClouderaStreamingOperators && kubectl apply --filename kafka-eval.yaml,kafka-nodepool.yaml --namespace cld-streaming && kubectl apply -f cluster-issuer.yaml && kubectl apply -f nifi-cluster-30-nifi2x-windows.yaml -n cfm-streaming && kubectl apply -f nifi-combined.yaml

## a git commit if chat made any repo changes
/bash cd DesktopShare && git add . && git commit -m "Tuna" && git push

/bash cd .config/zellij/layouts && cp kube-dev.kdl /home/tunas/DesktopShare/files/zellij-kubecolor-vtop.kdl && cp kube-service-ports.kdl /home/tunas/DesktopShare/files/zellij-sample-args.kdl && cp kube-service-ports-gemini.kdl /home/tunas/DesktopShare/kube-service-ports-cso.kdl

/bash cd DesktopShare && git add . && git commit -m "Tuna Street Push Zellij" && git push
```