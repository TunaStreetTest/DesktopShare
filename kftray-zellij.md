
## Kftray

kftray Graphical UI to start/stop multiple saved port forward configs.
 
 - https://kftray.app/downloads
 - https://kftray.app/docs/getting-started/quick-start


Create the config `~/.config/kftray/config.json`:

```bash
[
  {
    "alias": "kafka",
    "context": "my-cluster",
    "namespace": "cld-streaming",
    "workload_type": "service",
    "service": "my-cluster-kafka-bootstrap",
    "protocol": "tcp",
    "local_port": 9092,
    "remote_port": 9092,
    "local_address": "0.0.0.0"
  },
  {
    "alias": "web-efm",
    "context": "my-cluster",
    "namespace": "cld-streaming",
    "workload_type": "service",
    "service": "efm",
    "protocol": "tcp",
    "local_port": 10090,
    "remote_port": 10090,
    "local_address": "0.0.0.0"
  }
]
```

Run it with this:

```bash
kftui
```



## Zellij

Zellij is a modern, Rust-based terminal workspace and multiplexer. 

- https://zellij.dev/about/
- https://zellij.dev/documentation/

Create the layout: `~/.config/zellij/layout/kube-service-ports-mac-cso-observability.kdl`

```bash
layout {
    split_direction "Horizontal"

    pane {
        command "/opt/homebrew/bin/minikube"
        args "mount" "/Users/steven.matison/Documents/GitHub/NiFi2 Processor Playground/nifi-custom-processors/:/extensions" "--uid" "10001" "--gid" "10001"
    }

    pane {
        command "bash"
        args "-lc" "sudo /opt/homebrew/bin/minikube tunnel"
    }

    pane {
        command "/opt/homebrew/bin/minikube"
        args "service" "efm" "-n" "cld-streaming"
    }

    pane {
        command "/opt/homebrew/bin/minikube"
        args "service" "cloudera-surveyor-service" "--namespace" "cld-streaming"
    }

    pane {
        command "/opt/homebrew/bin/minikube"
        args "service" "prometheus-grafana" "--namespace" "cld-streaming"
    }

    pane {
        command "/usr/local/bin/kubectl"
        args "port-forward" "--address" "0.0.0.0" "service/my-cluster-kafka-bootstrap" "9092:9092" "-n" "cld-streaming"
    }

    pane {
        command "/usr/local/bin/kubectl"
        args "port-forward" "--address" "0.0.0.0" "service/efm" "10090:10090" "-n" "cld-streaming"
    }

}
```

Run it with this:

```bash
zellij --layout kube-service-ports-mac-cso-observability
```

