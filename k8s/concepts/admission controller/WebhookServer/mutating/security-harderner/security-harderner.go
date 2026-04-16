package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
)

type patchOp struct {
	Op    string      `json:"op"`
	Path  string      `json:"path"`
	Value interface{} `json:"value,omitempty"`
}

func mutate(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	defer r.Body.Close()

	var review admissionv1.AdmissionReview
	json.Unmarshal(body, &review)

	var pod corev1.Pod
	json.Unmarshal(review.Request.Object.Raw, &pod)

	var patches []patchOp

	// --- 1. Security context per container ---
	for i, c := range pod.Spec.Containers {
		base := fmt.Sprintf("/spec/containers/%d/securityContext", i)

		if c.SecurityContext == nil {
			patches = append(patches, patchOp{
				Op:   "add",
				Path: base,
				Value: map[string]interface{}{
					"runAsNonRoot":             true,
					"readOnlyRootFilesystem":   true,
					"allowPrivilegeEscalation": false,
				},
			})
		} else {
			if c.SecurityContext.RunAsNonRoot == nil {
				patches = append(patches, patchOp{
					Op: "add", Path: base + "/runAsNonRoot", Value: true,
				})
			}
			if c.SecurityContext.ReadOnlyRootFilesystem == nil {
				patches = append(patches, patchOp{
					Op: "add", Path: base + "/readOnlyRootFilesystem", Value: true,
				})
			}
			if c.SecurityContext.AllowPrivilegeEscalation == nil {
				f := false
				_ = f
				patches = append(patches, patchOp{
					Op: "add", Path: base + "/allowPrivilegeEscalation", Value: false,
				})
			}
		}

		// --- 2. Drop all caps, conditionally add NET_BIND_SERVICE ---
		needsPrivPort := false
		for _, p := range c.Ports {
			if p.ContainerPort < 1024 {
				needsPrivPort = true
				break
			}
		}
		caps := map[string]interface{}{"drop": []string{"ALL"}}
		if needsPrivPort {
			caps["add"] = []string{"NET_BIND_SERVICE"}
		}
		patches = append(patches, patchOp{
			Op: "add", Path: base + "/capabilities", Value: caps,
		})
	}

	// --- 3. automountServiceAccountToken ---
	ann := pod.GetAnnotations()
	if ann["iam.k8s.io/automount"] != "true" {
		if pod.Spec.AutomountServiceAccountToken == nil {
			patches = append(patches, patchOp{
				Op: "add", Path: "/spec/automountServiceAccountToken", Value: false,
			})
		}
	}

	// --- 4. Hardened annotation ---
	if ann == nil {
		patches = append(patches, patchOp{
			Op: "add", Path: "/metadata/annotations", Value: map[string]string{
				"security.k8s.io/hardened": "true",
			},
		})
	} else {
		patches = append(patches, patchOp{
			Op: "add", Path: "/metadata/annotations/security.k8s.io~1hardened",
			Value: "true",
		})
	}

	patchBytes, _ := json.Marshal(patches)
	pt := admissionv1.PatchTypeJSONPatch

	review.Response = &admissionv1.AdmissionResponse{
		UID:       review.Request.UID,
		Allowed:   true,
		PatchType: &pt,
		Patch:     patchBytes,
	}
	review.Request = nil

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(review)
}

func main() {
	http.HandleFunc("/mutate", mutate)
	log.Println("Starting webhook on :8443")
	log.Fatal(http.ListenAndServeTLS(":8443", "/tls/tls.crt", "/tls/tls.key", nil))
}