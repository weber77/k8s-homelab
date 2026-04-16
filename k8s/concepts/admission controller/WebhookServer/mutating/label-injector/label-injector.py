from flask import Flask, request, jsonify
import base64, json, copy

app = Flask(__name__)

@app.route("/mutate", methods=["POST"])
def mutate():
    review = request.get_json()
    req = review["request"]
    pod = req["object"]
    patches = []
    labels = pod.get("metadata", {}).get("labels")
    if labels is None:
        patches.append({"op": "add", "path": "/metadata/labels", "value": {}})
        labels = {}
    if "team" not in labels:
        patches.append({
            "op": "add",
            "path": "/metadata/labels/team",
            "value": "unassigned"
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
        }
    })
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8443, ssl_context=("/tls/tls.crt", "/tls/tls.key"))