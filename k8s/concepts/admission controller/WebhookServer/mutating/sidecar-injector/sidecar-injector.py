from flask import Flask, request, jsonify
import base64, json

app = Flask(__name__)

SIDECAR = {
    "name": "fluent-bit",
    "image": "fluent/fluent-bit:3.1",
    "resources": {
        "requests": {"cpu": "50m", "memory": "64Mi"},
        "limits":   {"cpu": "100m", "memory": "128Mi"},
    },
    "volumeMounts": [
        {"name": "varlog", "mountPath": "/var/log", "readOnly": True}
    ],
}
VOLUME = {"name": "varlog", "emptyDir": {}}

@app.route("/mutate", methods=["POST"])
def mutate():
    review = request.get_json()
    req = review["request"]
    pod = req["object"]
    patches = []
    container_names = [c["name"] for c in pod["spec"].get("containers", [])]
    if "fluent-bit" not in container_names:
        patches.append({
            "op": "add",
            "path": "/spec/containers/-",
            "value": SIDECAR,
        })
        volumes = pod["spec"].get("volumes")
        if volumes is None:
            patches.append({
                "op": "add",
                "path": "/spec/volumes",
                "value": [VOLUME],
            })
        else:
            volume_names = [v["name"] for v in volumes]
            if "varlog" not in volume_names:
                patches.append({
                    "op": "add",
                    "path": "/spec/volumes/-",
                    "value": VOLUME,
                })
    patch_bytes = base64.b64encode(json.dumps(patches).encode()).decode()
    return jsonify({
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "response": {
            "uid": req["uid"],
            "allowed": True,
            "patchType": "JSONPatch",
            "patch": patch_bytes,
        },
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8443,
            ssl_context=("/tls/tls.crt", "/tls/tls.key"))