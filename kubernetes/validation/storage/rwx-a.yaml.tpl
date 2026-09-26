apiVersion: v1
kind: Pod
metadata:
  name: rwx-a
  namespace: cvat-storage-validation
  labels:
    app.kubernetes.io/part-of: cvat-storage-validation
    validation.cvat.ai/scenario: rwx
    validation.cvat.ai/participant: a
spec:
  restartPolicy: Never
  tolerations:
    - key: workload
      operator: Equal
      value: cvat
      effect: NoSchedule
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: workload
                operator: In
                values:
                  - cvat
              - key: kubernetes.io/hostname
                operator: In
                values:
                  - __NODE_NAME__
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: shell
      image: busybox:1.36.1
      command: ["sh", "-c", "trap 'exit 0' TERM INT; while true; do sleep 3600; done"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 100m
          memory: 64Mi
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: rwx-test
