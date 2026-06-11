#efm
minikube service efm -n cld-streaming
kubectl port-forward --address 0.0.0.0 service/my-cluster-kafka-bootstrap 9092:9092 -n cld-streaming
kubectl port-forward --address 0.0.0.0 service/efm 10090:10090 -n cld-streaming

# nifi ui
minikube tunnel


# kafka 
kubectl port-forward --address 0.0.0.0 service/my-cluster-kafka-bootstrap 9092:9092 -n cld-streaming


# see zellij- *.kdl files for new screen panels.