# ================================================================================
# OCI API Gateway
# ================================================================================
# Creates a public API Gateway and a deployment with five routes that map
# HTTP methods + paths to the corresponding OCI Functions.
#
# Routes:
#   POST   /notes        → create-note
#   GET    /notes        → list-notes
#   GET    /notes/{id}   → get-note
#   PUT    /notes/{id}   → update-note
#   DELETE /notes/{id}   → delete-note
#
# Path parameters:
#   For routes containing {id}, a header transformation policy injects
#   ${request.path[id]} as X-Note-Id before the function is invoked.
#   The function reads ctx.Headers().get("x-note-id") to retrieve the value.
#
# CORS:
#   Configured at the deployment specification level so it applies to all
#   routes.  The gateway handles OPTIONS preflight requests automatically.
# ================================================================================

# --------------------------------------------------------------------------------
# API Gateway — public endpoint in the shared subnet
# --------------------------------------------------------------------------------
resource "oci_apigateway_gateway" "notes" {
  compartment_id = var.compartment_id
  display_name   = "notes-gateway"
  endpoint_type  = "PUBLIC"
  subnet_id      = oci_core_subnet.public.id
}

# --------------------------------------------------------------------------------
# API Deployment — routes, CORS, and function backends
# --------------------------------------------------------------------------------
resource "oci_apigateway_deployment" "notes" {
  compartment_id = var.compartment_id
  display_name   = "notes-api"
  gateway_id     = oci_apigateway_gateway.notes.id
  path_prefix    = "/"

  specification {

    # CORS — applies to all routes; gateway handles OPTIONS preflight automatically.
    request_policies {
      cors {
        allowed_origins              = ["*"]
        allowed_methods              = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
        allowed_headers              = ["Content-Type", "content-type"]
        exposed_headers              = ["Content-Type"]
        is_allow_credentials_enabled = false
        max_age_in_seconds           = 300
      }
    }

    # ------------------------------------------------------------------
    # POST /notes — create a new note
    # ------------------------------------------------------------------
    routes {
      path    = "/notes"
      methods = ["POST"]

      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.create_note.id
      }
    }

    # ------------------------------------------------------------------
    # GET /notes — list all notes
    # ------------------------------------------------------------------
    routes {
      path    = "/notes"
      methods = ["GET"]

      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.list_notes.id
      }
    }

    # ------------------------------------------------------------------
    # GET /notes/{id} — retrieve a single note
    # ------------------------------------------------------------------
    # Header transform injects the path parameter so the function
    # can read it from ctx.Headers().get("x-note-id").
    # ------------------------------------------------------------------
    routes {
      path    = "/notes/{id}"
      methods = ["GET"]

      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.get_note.id
      }

      request_policies {
        header_transformations {
          set_headers {
            items {
              name      = "X-Note-Id"
              values    = ["$${request.path[id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    # ------------------------------------------------------------------
    # PUT /notes/{id} — update an existing note
    # ------------------------------------------------------------------
    routes {
      path    = "/notes/{id}"
      methods = ["PUT"]

      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.update_note.id
      }

      request_policies {
        header_transformations {
          set_headers {
            items {
              name      = "X-Note-Id"
              values    = ["$${request.path[id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }

    # ------------------------------------------------------------------
    # DELETE /notes/{id} — delete a note
    # ------------------------------------------------------------------
    routes {
      path    = "/notes/{id}"
      methods = ["DELETE"]

      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.delete_note.id
      }

      request_policies {
        header_transformations {
          set_headers {
            items {
              name      = "X-Note-Id"
              values    = ["$${request.path[id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }
  }
}
