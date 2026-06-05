#!/bin/bash


helm uninstall cfm-operator --namespace cfm-streaming
helm uninstall cloudera-surveyor --namespace cld-streaming
helm uninstall strimzi-cluster-operator --namespace cld-streaming
helm uninstall schema-registry --namespace cld-streaming
helm uninstall csa-operator --namespace cld-streaming

echo "Success: ✅ 

  cfm-operator
  cloudera-surveyor
  strimzi-cluster-operators
  schema-registry
  csa-operator

Uninstalled!!"