
The following sample commands I am using to get started

```bash
/bash cd DesktopShare && git pull

/bash source .env && nohup sh ./DesktopShare/files/agent-install-operators.sh > deploy.log 2>&1 &

/bash source .env && cd ClouderaStreamingOperators && kubectl apply --filename kafka-eval.yaml,kafka-nodepool.yaml --namespace cld-streaming && kubectl apply -f cluster-issuer.yaml && kubectl apply -f nifi-cluster-30-nifi2x.yaml -n cfm-streaming && kubectl apply -f nifi-combined.yaml


/bash git add . && git commit -m "your commit message" && git push



```

