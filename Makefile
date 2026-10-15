SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# 1 dossier par FQDN : certs/<fqdn>/{openssl.cnf,key,csr}
DIR = certs/$(subst *,_wildcard,$(FQDN))

help:
	@echo "Usage : make csr FQDN=www.example.com"
	@echo "  - crée certs/<fqdn>/openssl.cnf (questions) s'il n'existe pas"
	@echo "    (tu peux ensuite l'éditer à la main et relancer make csr)"
	@echo "  - si une clé existe, demande si on la garde ou si on la régénère"
	@echo "  - génère certs/<fqdn>/<fqdn>.csr"

csr:
	@test -n "$(FQDN)" || { echo "Usage : make csr FQDN=www.example.com" >&2; exit 1; }
	mkdir -p "$(DIR)"
	CNF="$(DIR)/openssl.cnf"; KEY="$(DIR)/key.pem"; CSR="$(DIR)/$(subst *,_wildcard,$(FQDN)).csr"

	# --- openssl.cnf : créé via questions seulement s'il n'existe pas ---
	if [ ! -f "$$CNF" ]; then
	  ask() { local v; read -r -p "$$1 [$$2] : " v; echo "$${v:-$$2}"; }
	  C=$$(ask "Pays" "FR"); ST=$$(ask "Région" "Ile-de-France"); L=$$(ask "Ville" "Paris")
	  O=$$(ask "Organisation" "MonOrganisation"); OU=$$(ask "Unité" "IT")
	  SANS=$$(ask "SAN (séparés par espaces, DNS ou IP)" "$(FQDN)")
	  {
	    printf '[req]\ndefault_md = sha256\nprompt = no\ndistinguished_name = dn\nreq_extensions = ext\n\n'
	    printf '[dn]\nC = %s\nST = %s\nL = %s\nO = %s\nOU = %s\nCN = %s\n\n' "$$C" "$$ST" "$$L" "$$O" "$$OU" "$(FQDN)"
	    printf '[ext]\nsubjectAltName = @san\n\n[san]\n'
	    d=0; i=0
	    for s in $$SANS; do
	      if [[ "$$s" =~ ^[0-9.]+$$ || "$$s" == *:* ]]; then i=$$((i+1)); echo "IP.$$i = $$s"; else d=$$((d+1)); echo "DNS.$$d = $$s"; fi
	    done
	  } > "$$CNF"
	  echo "-> $$CNF créé"
	fi

	# --- clé : garder ou régénérer ---
	gen=1
	if [ -f "$$KEY" ]; then
	  read -r -p "Clé existante. La garder ? [O/n] : " a
	  case "$${a:-o}" in [nN]*) mv "$$KEY" "$$KEY.$$(date +%Y%m%d%H%M%S).bak" ;; *) gen=0 ;; esac
	fi
	if [ "$$gen" = 1 ]; then
	  (umask 077; openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:$${BITS:-2048} -out "$$KEY" 2>/dev/null)
	  echo "-> nouvelle clé : $$KEY"
	fi

	# --- CSR ---
	openssl req -new -config "$$CNF" -key "$$KEY" -out "$$CSR"
	echo "-> $$CSR"

.PHONY: help csr
