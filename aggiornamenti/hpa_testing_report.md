# DUKA Project: Load, Integrity, and Resilience Testing Update

This is an update on the additional tests performed after the main HPA verification.
The goal was to make the final demo stronger by showing not only that the Gateway scales under load, but also how the system behaves under stress, during recovery, and while preserving data correctness.

## Current Scripts

The current scripts in the `scripts/` folder are:

- `autoscaling-test.sh`
- `hpa-load-test-profiles.sh`
- `integrity-under-load-test.sh`
- `gateway-resilience-kill-test.sh`

---

## 1. HPA Load Testing

We already verified the HPA behavior using:

```bash
./autoscaling-test.sh
```

This script generates upload traffic against the Gateway and allows us to trigger CPU-based autoscaling.

The HPA is configured to scale the Gateway between `1` and `4` replicas when CPU usage goes above the configured threshold.

Recommended monitoring command:

```bash
watch -n 1 "kubectl get hpa -n duka; echo '----------------'; kubectl get pods -n duka"
```

What we can show during the demo:

- CPU usage increases under concurrent uploads.
- HPA increases the number of Gateway replicas.
- New Gateway pods are created automatically.
- Once traffic decreases, the system can eventually scale back down.

---

## 2. Load Test Profiles

We added a profile-based load test script:

```bash
./hpa-load-test-profiles.sh
```

This gives us multiple controlled levels of load:

- `leggero`: `1MB x 10` concurrent requests
- `medio`: `1MB x 30` concurrent requests
- `medio50`: `1MB x 50` concurrent requests
- `aggressivo`: `10MB x 50` concurrent requests

Example commands:

```bash
./hpa-load-test-profiles.sh leggero
./hpa-load-test-profiles.sh medio
./hpa-load-test-profiles.sh medio50
./hpa-load-test-profiles.sh aggressivo
```

Why this is useful:

- The light and medium tests show normal behavior under sustainable load.
- The `medio50` test is useful for triggering HPA more clearly.
- The aggressive test helps demonstrate system limits, such as memory pressure or `OOMKilled` behavior.

This gives us a more realistic discussion than simply saying "the system scales".
We can explain that HPA reacts to metrics, but it cannot prevent every failure mode, especially very fast memory spikes.

---

## 3. Integrity Under Load Test

We added an integrity test under load:

```bash
./integrity-under-load-test.sh
```

The idea is:

1. Start concurrent uploads to put pressure on the Gateway.
2. Upload a separate sample file while the system is under load.
3. Download the same file using its `file_id`.
4. Compare the checksum of the original file and the downloaded file.

This demonstrates that the system is not only handling traffic, but also preserving end-to-end correctness:

- upload;
- encryption;
- sharding;
- metadata handling;
- download;
- reassembly/decryption;
- checksum verification.

Expected successful result:

```text
SUCCESS: checksums are identical.
The system preserves data integrity even under load.
```

This is a strong demo point because it connects scalability with correctness.
The system should not only be elastic; it should still return the same file after encryption, sharding, distribution, retrieval, and reconstruction.

---

## 4. Gateway Resilience Test: Killing a Pod During Load

We added a resilience test:

```bash
./gateway-resilience-kill-test.sh
```

Scenario:

1. The Gateway receives continuous upload traffic.
2. During the load, we manually delete one Gateway pod.
3. Kubernetes must recreate the pod through the Deployment controller.
4. We observe how many requests still succeed and whether the system recovers.

The important concept is Kubernetes reconciliation:

> Kubernetes does not magically preserve requests that were already in progress when a pod is deleted.
> However, the Deployment controller detects that the desired state is no longer satisfied and creates a replacement pod automatically.

---

## 4.1 Result: Starting From 1 Gateway Replica

Initial condition:

- `1` Gateway replica running.

Result:

- Total completed requests: `183`
- HTTP `2xx/3xx` successes: `142`
- Failed or non-`2xx/3xx` responses: `41`
- HTTP `000` responses: `41`
- HTTP `100 Continue` responses: `0`

HTTP code distribution:

```text
142 200
 41 000
```

The last curl errors were connection refused errors:

```text
curl: (7) Failed to connect to 10.106.233.31 port 8080: Connection refused
```

Final Gateway state:

- `3` Gateway pods running.

Interpretation:

Starting from a single replica makes the failure visible.
When the only Gateway pod is deleted, there is a short interval where the Service has no ready backend, so some curl requests receive HTTP `000` / connection refused.

This is expected and honest to show in the demo:

- Kubernetes restores the desired state.
- The Deployment recreates the Gateway pod.
- HPA can also scale the Gateway up under load.
- Requests already in progress may still fail during the failure window.

This is a good **failure and recovery** demonstration.

---

## 4.2 Result: Starting From 3 Gateway Replicas

Initial condition:

- `3` Gateway replicas running.

Result:

- Total completed requests: `176`
- HTTP `2xx/3xx` successes: `176`
- Failed or non-`2xx/3xx` responses: `0`
- HTTP `000` responses: `0`
- HTTP `100 Continue` responses: `0`

HTTP code distribution:

```text
176 200
```

Final Gateway state:

- `4` Gateway pods running.

Interpretation:

Starting from three replicas makes the system much more resilient from the user's point of view.
When one Gateway pod is deleted, the other replicas continue serving traffic, so the client sees no failed requests.

This is the stronger high-availability result:

- One pod can fail.
- Traffic continues through the remaining Gateway pods.
- Kubernetes recreates the deleted pod.
- HPA can scale up to `4` replicas while the load continues.

This demonstrates why multiple replicas matter in production.

---

## 5. Key Takeaway From the Two Resilience Runs

The two resilience runs are not contradictory.
They show two different operating modes:

### Single-Replica Mode

- Failure is visible.
- Some requests fail while Kubernetes recreates the Gateway pod.
- This is useful to demonstrate recovery and reconciliation.

### Multi-Replica Mode

- Failure is hidden from the client.
- Other pods continue serving traffic while Kubernetes replaces the failed pod.
- This is useful to demonstrate high availability.

Good sentence for the presentation:

> With one Gateway replica, deleting the pod creates a short visible failure window.
> With three replicas, the same failure is absorbed by the remaining pods, and all requests succeed.
> This shows the difference between simple recovery and real high availability.

---

## 6. Final Summary for the Professor

These tests demonstrate four important properties:

1. **Elasticity**: HPA scales the Gateway under upload load.
2. **Controlled stress testing**: different load profiles allow us to observe normal load, HPA-triggering load, and overly aggressive load.
3. **Correctness**: the integrity test verifies that upload and download preserve the same checksum even while the system is under load.
4. **Resilience**: if a Gateway pod is killed, Kubernetes recreates it. With multiple replicas, the system can continue serving traffic without visible client-side failures.

The most valuable part of these tests is that they show realistic behavior:

- HPA helps with CPU pressure, but does not instantly solve every failure mode.
- Very aggressive uploads can still create memory pressure.
- HTTP `000` can happen when a pod is deleted and no ready backend is available.
- Multiple Gateway replicas significantly improve availability.
- Kubernetes guarantees desired-state reconciliation, not automatic preservation of every in-flight request.

This gives us a stronger and more honest story for the final project presentation.
