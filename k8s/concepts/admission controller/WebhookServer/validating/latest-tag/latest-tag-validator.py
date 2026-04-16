from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route("/validate", methods=["POST"])
def validate():
    review = request.get_json()
    req = review["request"]
    pod = req["object"]
    violations = []
    all_containers = (
        pod["spec"].get("containers", [])
        + pod["spec"].get("initContainers", [])
    )
    for c in all_containers:
        image = c.get("image", "")
        if ":" not in image or image.endswith(":latest"):
            violations.append(
                f"container '{c['name']}' uses image '{image}' - "
                "a specific, immutable tag or digest is required"
            )
    allowed = len(violations) == 0
    status = {"code": 200} if allowed else {
        "code": 403,
        "message": "Image policy violation:\n" + "\n".join(violations),
    }
    return jsonify({
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "response": {
            "uid": req["uid"],
            "allowed": allowed,
            "status": status,
        },
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8443,
            ssl_context=("/tls/tls.crt", "/tls/tls.key"))