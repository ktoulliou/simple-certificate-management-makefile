# =============================================================================
# Gestion de certificats (CSR / clé / openssl.cnf / packaging)
# 1 dossier = 1 FQDN :  certs/<fqdn>/{openssl.cnf,<fqdn>.key,<fqdn>.csr,<fqdn>.crt,...}
# =============================================================================

SHELL        := /bin/bash
.SHELLFLAGS  := -eu -o pipefail -c
.ONESHELL:
.DEFAULT_GOAL := help

# ---- Paramètres (surchargeables : make csr FQDN=x BITS=4096) ----------------
# KEY_TYPE : rsa | ec      BITS : taille RSA      CURVE : courbe EC
# NEW_KEY=1 : régénère la clé (ancienne sauvegardée en .bak)
# FORCE=1   : écrase sans demander (init)
# P12_PASS  : mot de passe PKCS#12 / JKS / PKCS#8 (sinon demandé)
# P12_COMPAT=1 : chiffrement 3DES/SHA1 (vieux Java, vieux Venafi)
# CERT / CHAIN : certificat signé / chaîne à importer (import-cert)
CERTS_DIR ?= certs
FQDN      ?=
KEY_TYPE  ?= rsa
BITS      ?= 2048
CURVE     ?= prime256v1
NEW_KEY   ?=
FORCE     ?=
P12_PASS  ?=
P12_COMPAT?=
CERT      ?=
CHAIN     ?=

# Dossier : '*' remplacé pour les wildcards (*.example.com -> _wildcard.example.com)
NAME  := $(subst *,_wildcard,$(FQDN))
DIR   := $(CERTS_DIR)/$(NAME)
CNF   := $(DIR)/openssl.cnf
KEY   := $(DIR)/$(NAME).key
CSR   := $(DIR)/$(NAME).csr
CRT   := $(DIR)/$(NAME).crt
CHN   := $(DIR)/$(NAME).chain.pem

# Valeurs par défaut du questionnaire (surchargeables en variable d'env)
DEFAULT_C  ?= FR
DEFAULT_ST ?= Ile-de-France
DEFAULT_L  ?= Paris
DEFAULT_O  ?= MonOrganisation
DEFAULT_OU ?= IT
DEFAULT_EMAIL ?=

define need_fqdn
test -n "$(FQDN)" || { echo "Erreur : FQDN manquant. Ex : make $@ FQDN=www.example.com" >&2; exit 1; }
endef
define need_cnf
test -f "$(CNF)" || { echo "Erreur : $(CNF) introuvable. Lance d'abord : make init FQDN=$(FQDN)" >&2; exit 1; }
endef
define need_key
test -f "$(KEY)" || { echo "Erreur : $(KEY) introuvable. Lance : make key FQDN=$(FQDN)" >&2; exit 1; }
endef
define need_crt
test -f "$(CRT)" || { echo "Erreur : $(CRT) introuvable. Lance : make import-cert FQDN=$(FQDN) CERT=fichier.crt" >&2; exit 1; }
endef
# Demande un mot de passe si P12_PASS est vide
define ask_pass
p="$(P12_PASS)"
if [ -z "$$p" ]; then read -r -s -p "Mot de passe : " p; echo; fi
test -n "$$p" || { echo "Erreur : mot de passe vide." >&2; exit 1; }
endef

.PHONY: help init edit key csr csr-newkey list \
        show-cnf show-key show-csr show-cert show-p12 show-all check \
        import-cert pem bundle pkcs8 der p12 jks package-all clean

# =============================================================================
##@ Aide
# =============================================================================
help: ## Affiche cette aide
	@echo "Gestion de certificats - usage : make <cible> FQDN=<fqdn> [VAR=valeur ...]"
	@echo
	@awk 'BEGIN{FS=":.*## "} \
	  /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0,5); next} \
	  /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Variables utiles : FQDN BITS=$(BITS) KEY_TYPE=$(KEY_TYPE) CURVE=$(CURVE) NEW_KEY=1 FORCE=1"
	@echo "                   P12_PASS=... P12_COMPAT=1 CERT=... CHAIN=... CERTS_DIR=$(CERTS_DIR)"
	@echo
	@echo "Exemple : make init FQDN=www.example.com && make csr FQDN=www.example.com"

# =============================================================================
##@ Création (openssl.cnf, clé, CSR)
# =============================================================================
init: ## Questionnaire interactif -> génère <fqdn>/openssl.cnf
	@$(need_fqdn)
	if [ -f "$(CNF)" ] && [ -z "$(FORCE)" ]; then
	  echo "$(CNF) existe déjà (FORCE=1 pour écraser, ou 'make edit')." >&2; exit 1
	fi
	mkdir -p "$(DIR)"
	ask() { local v; read -r -p "$$1 [$$2] : " v; echo "$${v:-$$2}"; }
	echo "=== Questionnaire pour $(FQDN) (Entrée = valeur par défaut) ==="
	C=$$(ask  "Pays (2 lettres)"          "$(DEFAULT_C)")
	ST=$$(ask "Région / État"             "$(DEFAULT_ST)")
	L=$$(ask  "Ville"                     "$(DEFAULT_L)")
	O=$$(ask  "Organisation"              "$(DEFAULT_O)")
	OU=$$(ask "Unité (OU, '-' pour aucun)" "$(DEFAULT_OU)")
	CN=$$(ask "Common Name (CN)"          "$(FQDN)")
	EM=$$(ask "Email ('-' pour aucun)"    "$(or $(DEFAULT_EMAIL),-)")
	SANS=$$(ask "SAN (DNS ou IP, séparés par espaces)" "$(FQDN)")
	EKU=$$(ask "Usage : 1=serveur 2=serveur+client 3=client" "1")
	case "$$EKU" in
	  2) EKU_V="serverAuth, clientAuth" ;;
	  3) EKU_V="clientAuth" ;;
	  *) EKU_V="serverAuth" ;;
	esac
	{
	  echo "# openssl.cnf pour $(FQDN) - modifiable à la main, puis : make csr FQDN=$(FQDN)"
	  echo "[ req ]"
	  echo "default_md         = sha256"
	  echo "prompt             = no"
	  echo "utf8               = yes"
	  echo "string_mask        = utf8only"
	  echo "distinguished_name = dn"
	  echo "req_extensions     = req_ext"
	  echo
	  echo "[ dn ]"
	  echo "C  = $$C"
	  echo "ST = $$ST"
	  echo "L  = $$L"
	  echo "O  = $$O"
	  [ "$$OU" = "-" ] || echo "OU = $$OU"
	  echo "CN = $$CN"
	  [ "$$EM" = "-" ] || echo "emailAddress = $$EM"
	  echo
	  echo "[ req_ext ]"
	  echo "basicConstraints = CA:FALSE"
	  echo "keyUsage         = critical, digitalSignature, keyEncipherment"
	  echo "extendedKeyUsage = $$EKU_V"
	  echo "subjectAltName   = @alt_names"
	  echo
	  echo "[ alt_names ]"
	  d=0; i=0
	  for s in $${SANS//,/ }; do
	    if [[ "$$s" =~ ^[0-9.]+$$ || "$$s" == *:* ]]; then i=$$((i+1)); echo "IP.$$i  = $$s"
	    else d=$$((d+1)); echo "DNS.$$d = $$s"; fi
	  done
	} > "$(CNF)"
	echo "-> $(CNF) créé. Suite : make csr FQDN=$(FQDN)"

edit: ## Ouvre openssl.cnf dans $EDITOR (défaut : vi)
	@$(need_fqdn); $(need_cnf)
	$${EDITOR:-vi} "$(CNF)"

key: ## Génère la clé privée (conservée si elle existe ; NEW_KEY=1 pour régénérer)
	@$(need_fqdn)
	mkdir -p "$(DIR)"
	if [ -f "$(KEY)" ] && [ -z "$(NEW_KEY)" ]; then
	  echo "Clé existante conservée : $(KEY)  (NEW_KEY=1 pour la régénérer)"; exit 0
	fi
	if [ -f "$(KEY)" ]; then
	  bak="$(KEY).$$(date +%Y%m%d%H%M%S).bak"; mv "$(KEY)" "$$bak"; echo "Ancienne clé sauvegardée : $$bak"
	fi
	umask 077
	case "$(KEY_TYPE)" in
	  rsa) openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:$(BITS) -out "$(KEY)" ;;
	  ec)  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:$(CURVE) -pkeyopt ec_param_enc:named_curve -out "$(KEY)" ;;
	  *)   echo "KEY_TYPE inconnu : $(KEY_TYPE) (rsa|ec)" >&2; exit 1 ;;
	esac
	chmod 600 "$(KEY)"
	echo "-> $(KEY) ($(KEY_TYPE))"

csr: key ## (Re)génère le CSR depuis openssl.cnf (crée la clé si absente ; NEW_KEY=1 pour la changer)
	@$(need_cnf)
	openssl req -new -config "$(CNF)" -key "$(KEY)" -out "$(CSR)"
	openssl req -in "$(CSR)" -noout -verify 2>&1 | sed 's/^/  /'
	echo "-> $(CSR)"
	openssl req -in "$(CSR)" -noout -subject | sed 's/^/  /'

csr-newkey: ## Raccourci : régénère clé + CSR
	@$(MAKE) --no-print-directory csr FQDN="$(FQDN)" NEW_KEY=1

list: ## Liste les FQDN gérés et leur état (clé / csr / crt / expiration)
	@printf "%-40s %-4s %-4s %-4s %s\n" FQDN KEY CSR CRT EXPIRE
	for d in "$(CERTS_DIR)"/*/; do
	  [ -d "$$d" ] || continue
	  n=$$(basename "$$d")
	  k=-; r=-; c=-; e=-
	  [ -f "$$d/$$n.key" ] && k=oui
	  [ -f "$$d/$$n.csr" ] && r=oui
	  if [ -f "$$d/$$n.crt" ]; then c=oui; e=$$(openssl x509 -in "$$d/$$n.crt" -noout -enddate | cut -d= -f2); fi
	  printf "%-40s %-4s %-4s %-4s %s\n" "$$n" "$$k" "$$r" "$$c" "$$e"
	done

# =============================================================================
##@ Affichage
# =============================================================================
show-cnf: ## Affiche openssl.cnf
	@$(need_fqdn); $(need_cnf)
	cat "$(CNF)"

show-key: ## Infos sur la clé (type, taille, empreinte publique) sans afficher le secret
	@$(need_fqdn); $(need_key)
	openssl pkey -in "$(KEY)" -noout -text | grep -E "Private-Key|Key|ASN1 OID|NIST" || true
	echo -n "Empreinte pubkey (sha256) : "
	openssl pkey -in "$(KEY)" -pubout | openssl sha256 | awk '{print $$2}'

show-csr: ## Affiche le contenu du CSR
	@$(need_fqdn)
	test -f "$(CSR)" || { echo "Erreur : $(CSR) introuvable (make csr)." >&2; exit 1; }
	openssl req -in "$(CSR)" -noout -text -verify

show-cert: ## Affiche le certificat signé (sujet, émetteur, dates, SAN, empreintes)
	@$(need_fqdn); $(need_crt)
	openssl x509 -in "$(CRT)" -noout -subject -issuer -serial -dates -fingerprint -sha256
	openssl x509 -in "$(CRT)" -noout -ext subjectAltName,keyUsage,extendedKeyUsage 2>/dev/null \
	  || openssl x509 -in "$(CRT)" -noout -text | grep -A1 -E "Subject Alternative|Key Usage"
	if openssl x509 -in "$(CRT)" -noout -checkend 0 >/dev/null; then
	  if openssl x509 -in "$(CRT)" -noout -checkend 2592000 >/dev/null; then echo "Statut : valide (> 30 jours)"
	  else echo "Statut : ATTENTION expire dans moins de 30 jours"; fi
	else echo "Statut : EXPIRÉ"; fi

show-p12: ## Affiche le contenu du PKCS#12 (mot de passe demandé si P12_PASS vide)
	@$(need_fqdn)
	f="$(DIR)/$(NAME).p12"; test -f "$$f" || { echo "Erreur : $$f introuvable (make p12)." >&2; exit 1; }
	$(ask_pass)
	P="$$p" openssl pkcs12 -in "$$f" -nokeys -passin env:P -info 2>&1 | grep -vE "^-----|^[A-Za-z0-9+/=]{40,}$$" || true

show-all: ## Affiche cnf + clé + csr (+ cert s'il existe)
	@$(MAKE) --no-print-directory show-cnf FQDN="$(FQDN)"
	@$(MAKE) --no-print-directory show-key FQDN="$(FQDN)"
	@$(MAKE) --no-print-directory show-csr FQDN="$(FQDN)"
	@if [ -f "$(CRT)" ]; then $(MAKE) --no-print-directory show-cert FQDN="$(FQDN)"; fi

check: ## Vérifie la cohérence clé <-> CSR <-> certificat
	@$(need_fqdn); $(need_key)
	h() { sha256sum | cut -c1-16; }
	k=$$(openssl pkey -in "$(KEY)" -pubout | h)
	echo "clé  : $$k"
	rc=0
	if [ -f "$(CSR)" ]; then r=$$(openssl req -in "$(CSR)" -noout -pubkey | h)
	  echo "csr  : $$r $$([ "$$r" = "$$k" ] && echo OK || echo DIFFERENT)"; [ "$$r" = "$$k" ] || rc=1; fi
	if [ -f "$(CRT)" ]; then c=$$(openssl x509 -in "$(CRT)" -noout -pubkey | h)
	  echo "crt  : $$c $$([ "$$c" = "$$k" ] && echo OK || echo DIFFERENT)"; [ "$$c" = "$$k" ] || rc=1; fi
	exit $$rc

# =============================================================================
##@ Certificat signé et packaging (PEM / PKCS#8 / PKCS#12 / JKS / DER)
# =============================================================================
import-cert: ## Importe le cert signé : make import-cert FQDN=.. CERT=x.crt [CHAIN=chain.pem]
	@$(need_fqdn); $(need_key)
	test -n "$(CERT)" -a -f "$(CERT)" || { echo "Erreur : CERT=<fichier> requis." >&2; exit 1; }
	conv() { if openssl x509 -in "$$1" -noout 2>/dev/null; then openssl x509 -in "$$1"; else openssl x509 -inform DER -in "$$1"; fi; }
	conv "$(CERT)" > "$(CRT).tmp"
	a=$$(openssl pkey -in "$(KEY)" -pubout | sha256sum); b=$$(openssl x509 -in "$(CRT).tmp" -noout -pubkey | sha256sum)
	if [ "$$a" != "$$b" ]; then rm -f "$(CRT).tmp"; echo "Erreur : le certificat ne correspond pas à la clé." >&2; exit 1; fi
	mv "$(CRT).tmp" "$(CRT)"; echo "-> $(CRT)"
	if [ -n "$(CHAIN)" ]; then cp "$(CHAIN)" "$(CHN)"; echo "-> $(CHN)"; fi

pem: ## <fqdn>.fullchain.pem (cert + chaîne, sans clé)
	@$(need_fqdn); $(need_crt)
	cat "$(CRT)" $$([ -f "$(CHN)" ] && echo "$(CHN)") > "$(DIR)/$(NAME).fullchain.pem"
	echo "-> $(DIR)/$(NAME).fullchain.pem"

bundle: ## <fqdn>.bundle.pem (clé + cert + chaîne dans un seul PEM) - clé EN CLAIR
	@$(need_fqdn); $(need_key); $(need_crt)
	umask 077
	cat "$(KEY)" "$(CRT)" $$([ -f "$(CHN)" ] && echo "$(CHN)") > "$(DIR)/$(NAME).bundle.pem"
	echo "-> $(DIR)/$(NAME).bundle.pem (contient la clé privée !)"

pkcs8: ## <fqdn>.pkcs8.key (clé PKCS#8 chiffrée AES-256 ; P12_PASS vide = demandé)
	@$(need_fqdn); $(need_key)
	$(ask_pass)
	umask 077
	P="$$p" openssl pkcs8 -topk8 -v2 aes-256-cbc -in "$(KEY)" -out "$(DIR)/$(NAME).pkcs8.key" -passout env:P
	echo "-> $(DIR)/$(NAME).pkcs8.key"

der: ## <fqdn>.der (certificat au format DER)
	@$(need_fqdn); $(need_crt)
	openssl x509 -in "$(CRT)" -outform DER -out "$(DIR)/$(NAME).der"
	echo "-> $(DIR)/$(NAME).der"

p12: ## <fqdn>.p12 (PKCS#12 clé+cert+chaîne ; P12_COMPAT=1 pour vieux outils)
	@$(need_fqdn); $(need_key); $(need_crt)
	$(ask_pass)
	umask 077
	opts=""
	[ -n "$(P12_COMPAT)" ] && opts="-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1"
	P="$$p" openssl pkcs12 -export $$opts -name "$(FQDN)" -inkey "$(KEY)" -in "$(CRT)" \
	  $$([ -f "$(CHN)" ] && echo "-certfile $(CHN)") -out "$(DIR)/$(NAME).p12" -passout env:P
	echo "-> $(DIR)/$(NAME).p12"

jks: p12 ## <fqdn>.jks (Java keystore, via keytool, depuis le .p12)
	@command -v keytool >/dev/null || { echo "Erreur : keytool (JDK) introuvable." >&2; exit 1; }
	$(ask_pass)
	rm -f "$(DIR)/$(NAME).jks"
	keytool -importkeystore -srckeystore "$(DIR)/$(NAME).p12" -srcstoretype PKCS12 -srcstorepass:env p \
	  -destkeystore "$(DIR)/$(NAME).jks" -deststoretype JKS -deststorepass:env p -noprompt 2>&1 | grep -v "^Warning" || true
	echo "-> $(DIR)/$(NAME).jks"

package-all: pem der p12 ## Génère pem + der + p12 d'un coup (utilise P12_PASS)
	@echo "Packaging terminé dans $(DIR)"

# =============================================================================
##@ Nettoyage
# =============================================================================
clean: ## Supprime les fichiers générés d'un FQDN (garde cnf, key, csr, crt) : packages seulement
	@$(need_fqdn)
	rm -f "$(DIR)"/$(NAME).{fullchain.pem,bundle.pem,pkcs8.key,der,p12,jks}
	echo "Packages supprimés dans $(DIR)"
