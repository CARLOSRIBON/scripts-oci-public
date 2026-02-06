#!/bin/bash

# Script para extraer políticas de OCI con análisis jerárquico completo
# Versión optimizada para OCI Cloud Shell (delegation token auth)
# Compatible con bash estándar

set -euo pipefail

# Colores para la salida
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Detección de entorno ─────────────────────────────────────────────────────
# Cloud Shell expone OCI_TENANCY, OCI_REGION y OCI_CS_USER_OCID
IS_CLOUD_SHELL=false
AUTH_ARGS=""

if [ -n "${OCI_TENANCY:-}" ] && [ -n "${OCI_CS_USER_OCID:-}" ]; then
    IS_CLOUD_SHELL=true
    AUTH_ARGS="--auth security_token"
    echo -e "${GREEN}✔ Entorno detectado: OCI Cloud Shell${NC}"
    echo -e "${GREEN}  Región: ${OCI_REGION:-no definida}${NC}"
    echo -e "${GREEN}  Usuario: ${OCI_CS_USER_OCID}${NC}"
else
    echo -e "${YELLOW}⚠ No se detectó Cloud Shell. Intentando con perfil local...${NC}"
fi

# ── Resolución del Tenancy OCID ──────────────────────────────────────────────
if [ "$IS_CLOUD_SHELL" = true ]; then
    TENANCY_OCID="$OCI_TENANCY"
    OCI_PROFILE=""
else
    read -rp "Ingrese el nombre del perfil de OCI a utilizar [DEFAULT]: " OCI_PROFILE
    OCI_PROFILE=${OCI_PROFILE:-DEFAULT}

    TENANCY_OCID=$(grep -A5 "^\[${OCI_PROFILE}\]" ~/.oci/config | grep "^tenancy" | cut -d'=' -f2 | tr -d ' ')
    if [ -z "$TENANCY_OCID" ]; then
        echo -e "${RED}Error: No se pudo obtener el OCID del tenancy para el perfil '${OCI_PROFILE}'.${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}Tenancy OCID:${NC} $TENANCY_OCID"

# ── Función helper para llamadas OCI CLI ─────────────────────────────────────
# Encapsula la lógica de autenticación según el entorno
oci_cmd() {
    if [ "$IS_CLOUD_SHELL" = true ]; then
        oci "$@" --auth security_token
    else
        oci "$@" --profile "$OCI_PROFILE"
    fi
}

# Versión silenciosa para operaciones normales (después de verificar conectividad)
oci_cmd_quiet() {
    if [ "$IS_CLOUD_SHELL" = true ]; then
        oci "$@" --auth security_token 2>/dev/null
    else
        oci "$@" --profile "$OCI_PROFILE" 2>/dev/null
    fi
}

# ── Verificar conectividad ───────────────────────────────────────────────────
echo -e "${YELLOW}Verificando conectividad con OCI...${NC}"

# Capturar salida y error para diagnóstico
OCI_OUTPUT=$(mktemp)
OCI_ERROR=$(mktemp)
trap "rm -f $OCI_OUTPUT $OCI_ERROR" EXIT

# Desactivar exit on error temporalmente para capturar el código de salida
set +e
if [ "$IS_CLOUD_SHELL" = true ]; then
    oci iam region list --auth security_token > "$OCI_OUTPUT" 2> "$OCI_ERROR"
    OCI_EXIT_CODE=$?
else
    oci iam region list --profile "$OCI_PROFILE" > "$OCI_OUTPUT" 2> "$OCI_ERROR"
    OCI_EXIT_CODE=$?
fi
set -e

if [ $OCI_EXIT_CODE -ne 0 ]; then
    echo -e "${RED}Error: No se pudo conectar a OCI.${NC}"
    echo ""
    echo -e "${RED}Detalle del error:${NC}"
    cat "$OCI_ERROR"
    echo ""

    if [ "$IS_CLOUD_SHELL" = true ]; then
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}Posibles soluciones para Cloud Shell:${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "  1. ${CYAN}Cierre esta terminal y abra una nueva${NC}"
        echo -e "  2. ${CYAN}Si el problema persiste, cierre sesión de OCI Console y vuelva a entrar${NC}"
        echo -e "  3. ${CYAN}Verifique que su usuario tenga permisos para listar regiones${NC}"
        echo ""
        echo -e "${YELLOW}Comando de prueba manual:${NC}"
        echo -e "  ${CYAN}oci iam region list --auth security_token${NC}"
    else
        echo -e "${YELLOW}Verifique que el perfil '$OCI_PROFILE' esté configurado correctamente en ~/.oci/config${NC}"
    fi
    exit 1
fi
echo -e "${GREEN}✔ Conectividad verificada${NC}"

# ── Obtener nombre del tenancy ───────────────────────────────────────────────
TENANCY_NAME=$(oci_cmd_quiet iam tenancy get --tenancy-id "$TENANCY_OCID" | jq -r '.data.name // empty' 2>/dev/null || true)
TENANCY_NAME=${TENANCY_NAME:-"Tenancy"}
echo -e "${GREEN}Tenancy:${NC} $TENANCY_NAME"
echo ""

# ── Archivos de salida ───────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_OUTPUT="oci_policies_complete_${TIMESTAMP}.txt"
SUMMARY_OUTPUT="oci_policies_summary_${TIMESTAMP}.txt"
TEMP_TREE_FILE=$(mktemp /tmp/oci_tree_XXXXXX)
TEMP_STATS_FILE="${TEMP_TREE_FILE}.stats"

# Variables globales para estadísticas
TOTAL_COMPARTMENTS=0
TOTAL_POLICIES=0
TOTAL_STATEMENTS=0
COMPARTMENTS_WITH_POLICIES=0
COMPARTMENTS_WITHOUT_POLICIES=0

# ── Función de limpieza ──────────────────────────────────────────────────────
cleanup() {
    rm -f "$TEMP_TREE_FILE" "$TEMP_STATS_FILE"
}
trap cleanup EXIT INT TERM

# ── Función: banner para reportes ────────────────────────────────────────────
create_banner() {
    local title="$1"
    local file="$2"
    cat >> "$file" << EOF
################################################################################
#  ${title}
################################################################################
#
#  Tenancy : $TENANCY_NAME
#  Fecha   : $(date '+%Y-%m-%d %H:%M:%S')
#  Entorno : $([ "$IS_CLOUD_SHELL" = true ] && echo "Cloud Shell" || echo "Local (perfil: $OCI_PROFILE)")
#  Región  : ${OCI_REGION:-$(oci_cmd_quiet iam region-subscription list --tenancy-id "$TENANCY_OCID" | jq -r '.data[0]."region-name" // "N/A"' 2>/dev/null || echo "N/A")}
#
################################################################################

EOF
}

# ══════════════════════════════════════════════════════════════════════════════
# FASE 1: Descubrir el árbol de compartments de forma recursiva
# ══════════════════════════════════════════════════════════════════════════════
discover_compartment_tree() {
    local compartment_id=$1
    local compartment_name=$2
    local level=$3
    local parent_path="$4"

    echo -e "${CYAN}[FASE 1] Descubriendo: ${compartment_name} (Nivel ${level})${NC}"

    local full_path
    if [ "$level" -eq 0 ]; then
        full_path="$compartment_name"
    else
        full_path="${parent_path} > ${compartment_name}"
    fi

    # Guardar en archivo temporal
    echo "${compartment_id}|${compartment_name}|${level}|${full_path}" >> "$TEMP_TREE_FILE"
    TOTAL_COMPARTMENTS=$((TOTAL_COMPARTMENTS + 1))

    # Buscar subcompartments
    local subcompartments
    subcompartments=$(oci_cmd_quiet iam compartment list \
        --compartment-id "$compartment_id" \
        --lifecycle-state ACTIVE \
        --all) || true

    if [ -n "$subcompartments" ]; then
        local subcompartment_count
        subcompartment_count=$(echo "$subcompartments" | jq -r '.data | length' 2>/dev/null)
        subcompartment_count=${subcompartment_count:-0}

        if [ "$subcompartment_count" != "null" ] && [ "$subcompartment_count" -gt 0 ] 2>/dev/null; then
            echo -e "${BLUE}    └── ${subcompartment_count} subcompartments encontrados${NC}"

            local sub_counter=0
            while [ "$sub_counter" -lt "$subcompartment_count" ]; do
                local sub_id sub_name
                sub_id=$(echo "$subcompartments" | jq -r ".data[$sub_counter].id" 2>/dev/null)
                sub_name=$(echo "$subcompartments" | jq -r ".data[$sub_counter].name" 2>/dev/null)

                if [ -n "$sub_id" ] && [ "$sub_id" != "null" ] && [ -n "$sub_name" ] && [ "$sub_name" != "null" ]; then
                    discover_compartment_tree "$sub_id" "$sub_name" $((level + 1)) "$full_path"
                fi
                sub_counter=$((sub_counter + 1))
            done
        else
            echo -e "${BLUE}    └── 0 subcompartments${NC}"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# FASE 2: Buscar políticas en cada compartment
# ══════════════════════════════════════════════════════════════════════════════
search_all_policies() {
    echo -e "${YELLOW}[FASE 2] Analizando políticas en todos los compartments...${NC}"

    while IFS='|' read -r compartment_id compartment_name level full_path; do
        [ -z "$compartment_id" ] && continue

        echo -e "${YELLOW}  Analizando: ${compartment_name}${NC}"

        local policies policy_count=0 statement_count=0
        policies=$(oci_cmd_quiet iam policy list \
            --compartment-id "$compartment_id" \
            --all) || true

        if [ -n "$policies" ]; then
            policy_count=$(echo "$policies" | jq -r '.data | length' 2>/dev/null)
            policy_count=${policy_count:-0}
            [ "$policy_count" = "null" ] && policy_count=0

            if [ "$policy_count" -gt 0 ] 2>/dev/null; then
                COMPARTMENTS_WITH_POLICIES=$((COMPARTMENTS_WITH_POLICIES + 1))
                TOTAL_POLICIES=$((TOTAL_POLICIES + policy_count))

                echo -e "${GREEN}    └── ${policy_count} políticas encontradas${NC}"

                # Contar statements usando la lista directamente (evita llamadas extra)
                statement_count=$(echo "$policies" | jq '[.data[].statements | length] | add // 0' 2>/dev/null)
                statement_count=${statement_count:-0}
                TOTAL_STATEMENTS=$((TOTAL_STATEMENTS + statement_count))
            else
                COMPARTMENTS_WITHOUT_POLICIES=$((COMPARTMENTS_WITHOUT_POLICIES + 1))
                echo -e "${BLUE}    └── Sin políticas${NC}"
            fi
        else
            COMPARTMENTS_WITHOUT_POLICIES=$((COMPARTMENTS_WITHOUT_POLICIES + 1))
        fi

        echo "${compartment_id}|${compartment_name}|${level}|${full_path}|${policy_count}|${statement_count}" >> "$TEMP_STATS_FILE"

    done < "$TEMP_TREE_FILE"
}

# ══════════════════════════════════════════════════════════════════════════════
# FASE 3: Generar reporte detallado
# ══════════════════════════════════════════════════════════════════════════════
generate_detailed_report() {
    echo -e "${CYAN}[FASE 3] Generando reporte detallado...${NC}"

    sort -t'|' -k3n "$TEMP_STATS_FILE" | while IFS='|' read -r compartment_id compartment_name level full_path policy_count statement_count; do
        [ -z "$compartment_id" ] && continue

        # Crear indentación
        local indent=""
        local i=0
        while [ "$i" -lt "$level" ]; do
            indent="${indent}    "
            i=$((i + 1))
        done

        local prefix
        if [ "$level" -eq 0 ]; then
            prefix="[ROOT] "
        else
            prefix="${indent}└── "
        fi

        echo "${prefix}${compartment_name}" >> "$MAIN_OUTPUT"
        echo "    ${indent}Path: ${full_path}" >> "$MAIN_OUTPUT"
        echo "    ${indent}Políticas: ${policy_count} | Statements: ${statement_count}" >> "$MAIN_OUTPUT"

        if [ "$policy_count" -gt 0 ] 2>/dev/null; then
            local policies
            policies=$(oci_cmd_quiet iam policy list \
                --compartment-id "$compartment_id" \
                --all) || true

            if [ -n "$policies" ]; then
                local counter=0
                while [ "$counter" -lt "$policy_count" ]; do
                    local policy_id policy_name
                    policy_id=$(echo "$policies" | jq -r ".data[$counter].id" 2>/dev/null)
                    policy_name=$(echo "$policies" | jq -r ".data[$counter].name" 2>/dev/null)

                    if [ -n "$policy_id" ] && [ "$policy_id" != "null" ]; then
                        echo "" >> "$MAIN_OUTPUT"
                        echo "        ${indent}Política: ${policy_name}" >> "$MAIN_OUTPUT"
                        echo "        ${indent}  ID: ${policy_id}" >> "$MAIN_OUTPUT"
                        echo "        ${indent}  Statements:" >> "$MAIN_OUTPUT"

                        # Extraer statements directamente del list (ya los tiene)
                        echo "$policies" | jq -r ".data[$counter].statements[]" 2>/dev/null | while read -r statement; do
                            [ -n "$statement" ] && echo "        ${indent}    - ${statement}" >> "$MAIN_OUTPUT"
                        done
                    fi
                    counter=$((counter + 1))
                done
            fi
        fi
        echo "" >> "$MAIN_OUTPUT"
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# FASE 4: Generar resumen ejecutivo
# ══════════════════════════════════════════════════════════════════════════════
generate_executive_summary() {
    cat > "$SUMMARY_OUTPUT" << EOF
################################################################################
#              RESUMEN EJECUTIVO - POLÍTICAS OCI                               #
################################################################################
#
#  Tenancy : $TENANCY_NAME
#  Fecha   : $(date '+%Y-%m-%d %H:%M:%S')
#  Entorno : $([ "$IS_CLOUD_SHELL" = true ] && echo "Cloud Shell" || echo "Local (perfil: $OCI_PROFILE)")
#
################################################################################

ESTADÍSTICAS GENERALES
======================
  Compartments analizados    : $TOTAL_COMPARTMENTS
  Compartments con políticas : $COMPARTMENTS_WITH_POLICIES
  Compartments sin políticas : $COMPARTMENTS_WITHOUT_POLICIES
  Total de políticas         : $TOTAL_POLICIES
  Total de statements        : $TOTAL_STATEMENTS

DISTRIBUCIÓN POR COMPARTMENT
=============================
EOF

    printf "%-35s | %-10s | %s\n" "COMPARTMENT" "POLÍTICAS" "PATH" >> "$SUMMARY_OUTPUT"
    printf "%-35s-+-%-10s-+-%s\n" "-----------------------------------" "----------" "--------------------" >> "$SUMMARY_OUTPUT"

    while IFS='|' read -r _ compartment_name _ full_path policy_count _; do
        [ -z "$compartment_name" ] && continue
        printf "%-35s | %-10s | %s\n" "$compartment_name" "$policy_count" "$full_path" >> "$SUMMARY_OUTPUT"
    done < "$TEMP_STATS_FILE"

    cat >> "$SUMMARY_OUTPUT" << EOF

ANÁLISIS DE SEGURIDAD
=====================
EOF

    if [ "$TOTAL_COMPARTMENTS" -gt 0 ]; then
        local coverage=$((COMPARTMENTS_WITH_POLICIES * 100 / TOTAL_COMPARTMENTS))
        echo "  Cobertura de políticas: ${coverage}%" >> "$SUMMARY_OUTPUT"

        local avg_p=$((TOTAL_POLICIES * 100 / TOTAL_COMPARTMENTS))
        echo "  Promedio políticas/compartment: $((avg_p / 100)).$((avg_p % 100))" >> "$SUMMARY_OUTPUT"
    fi

    if [ "$TOTAL_POLICIES" -gt 0 ]; then
        local avg_s=$((TOTAL_STATEMENTS * 100 / TOTAL_POLICIES))
        echo "  Promedio statements/política: $((avg_s / 100)).$((avg_s % 100))" >> "$SUMMARY_OUTPUT"
    fi

    cat >> "$SUMMARY_OUTPUT" << EOF

RECOMENDACIONES
===============
EOF

    if [ "$COMPARTMENTS_WITHOUT_POLICIES" -gt "$COMPARTMENTS_WITH_POLICIES" ]; then
        echo "  [!] Más compartments sin políticas que con políticas." >> "$SUMMARY_OUTPUT"
        echo "      Revisar si es intencional o falta configuración." >> "$SUMMARY_OUTPUT"
    else
        echo "  [OK] Distribución de políticas aparenta estar balanceada." >> "$SUMMARY_OUTPUT"
    fi

    if [ "$TOTAL_POLICIES" -lt 5 ]; then
        echo "  [!] Muy pocas políticas detectadas (${TOTAL_POLICIES})." >> "$SUMMARY_OUTPUT"
        echo "      Verificar configuración de permisos." >> "$SUMMARY_OUTPUT"
    fi

    cat >> "$SUMMARY_OUTPUT" << EOF

================================================================================
Archivo de detalle: $MAIN_OUTPUT
Generado por: OCI Policies Hierarchical Analyzer v3.0 (Cloud Shell)
================================================================================
EOF
}

# ══════════════════════════════════════════════════════════════════════════════
#  EJECUCIÓN PRINCIPAL
# ══════════════════════════════════════════════════════════════════════════════

echo "=================================================================================="
echo -e "${GREEN}INICIANDO ANÁLISIS JERÁRQUICO DE POLÍTICAS OCI${NC}"
echo "=================================================================================="
echo ""

# FASE 1
echo -e "${CYAN}FASE 1: DESCUBRIMIENTO DEL ÁRBOL DE COMPARTMENTS${NC}"
echo "=================================================================================="
discover_compartment_tree "$TENANCY_OCID" "$TENANCY_NAME" 0 ""
echo ""
echo -e "${GREEN}✔ Árbol descubierto: ${TOTAL_COMPARTMENTS} compartments${NC}"
echo ""

# FASE 2
echo -e "${CYAN}FASE 2: BÚSQUEDA DE POLÍTICAS${NC}"
echo "=================================================================================="
search_all_policies
echo ""
echo -e "${GREEN}✔ Búsqueda completada${NC}"
echo ""

# FASE 3
echo -e "${CYAN}FASE 3: GENERACIÓN DE REPORTES${NC}"
echo "=================================================================================="
create_banner "OCI POLICIES - ANÁLISIS JERÁRQUICO" "$MAIN_OUTPUT"
echo "JERARQUÍA DE COMPARTMENTS Y POLÍTICAS:" >> "$MAIN_OUTPUT"
echo "=======================================" >> "$MAIN_OUTPUT"
echo "" >> "$MAIN_OUTPUT"

generate_detailed_report
generate_executive_summary

echo -e "${GREEN}✔ Reportes generados${NC}"
echo ""

# ── Resultados finales ───────────────────────────────────────────────────────
echo "=================================================================================="
echo -e "${GREEN}✔ ANÁLISIS COMPLETADO${NC}"
echo "=================================================================================="
echo -e "${CYAN}Archivos generados:${NC}"
echo -e "  Detalle completo  : ${YELLOW}${MAIN_OUTPUT}${NC}"
echo -e "  Resumen ejecutivo : ${YELLOW}${SUMMARY_OUTPUT}${NC}"
echo ""
echo -e "${CYAN}Estadísticas:${NC}"
echo -e "  Compartments : ${GREEN}${TOTAL_COMPARTMENTS}${NC}"
echo -e "  Políticas    : ${GREEN}${TOTAL_POLICIES}${NC}"
echo -e "  Statements   : ${GREEN}${TOTAL_STATEMENTS}${NC}"
echo -e "  Cobertura    : ${GREEN}${COMPARTMENTS_WITH_POLICIES}${NC}/${GREEN}${TOTAL_COMPARTMENTS}${NC} compartments con políticas"
echo ""
echo -e "${YELLOW}Resumen ejecutivo:${NC}"
echo "=================================================================================="
cat "$SUMMARY_OUTPUT"
