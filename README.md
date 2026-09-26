# CVAT on AKS POC

Proof of concept for evaluating CVAT deployment requirements on Azure Kubernetes Service (AKS).

## Objectives

- Understand CVAT's Kubernetes architecture and dependencies.
- Establish a minimal reproducible AKS deployment.
- Evaluate compute, storage, networking, and identity requirements.
- Validate CPU-based CVAT workloads first.
- Evaluate GPU-backed inference separately.
- Explore storage architecture suitable for large image/video datasets.
- Capture findings that can inform a production AKS platform design.

## Approach

This repository intentionally starts with a minimal AKS baseline.

Complex enterprise concerns such as hub/spoke networking, enterprise firewall integration,
centralized observability, private connectivity, and production HA will be evaluated after
the application requirements are understood.

## Status

Milestone 0 - Application discovery and AKS baseline.
