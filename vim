apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hubble-ui
  namespace: kube-system
spec:
  parentRefs:
    - name: eg-gateway
      namespace: gateway-demo
      sectionName: http

    - name: eg-gateway
      namespace: gateway-demo
      sectionName: https

  hostnames:
    - hubble.microservices.home.arpa

  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: hubble-ui
          port: 80
