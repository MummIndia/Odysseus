# -*- coding: utf-8 -*-
"""Relit les competences apprises par l'agent et signale celles qui posent probleme.

Une boucle d'apprentissage memorise ce qui s'est passe, pas ce qui etait juste :
une reponse produite avec assurance dans de mauvaises conditions devient une
competence, et sera rejouee. Le premier cas rencontre ici en est l'illustration
— l'agent avait memorise du code Python decrivant comment lister un dossier,
alors que le geste correct est d'appeler l'outil `ls`. Il l'avait enregistre
avec 0.9 de confiance, et reutilise une fois.

Ce script applique le critere qui separe les deux : une bonne competence decrit
des GESTES (des appels d'outils), une mauvaise decrit un RAISONNEMENT.

Usage :
    python scripts/review_skills.py
"""
import json
import os
import re
import sys

RACINE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "data", "skills")

# Les outils reellement disponibles a l'agent. Une procedure qui n'en nomme
# aucun ne decrit pas une action executable.
OUTILS = {
    "bash", "python", "ls", "glob", "grep", "read_file", "write_file",
    "edit_file", "web_search", "web_fetch", "manage_memory", "ask_user",
    "update_plan", "manage_skills", "manage_tasks", "manage_notes",
}

# Marqueurs de raisonnement : du code a ecrire plutot qu'un outil a appeler.
CODE = re.compile(r"\b(import\s+\w+|def\s+\w+|os\.\w+|print\s*\(|for\s+\w+\s+in\b)")


def lire(chemin):
    texte = open(chemin, encoding="utf-8").read()
    meta = {}
    if texte.startswith("---"):
        fin = texte.find("---", 3)
        if fin > 0:
            for ligne in texte[3:fin].splitlines():
                if ":" in ligne:
                    c, v = ligne.split(":", 1)
                    meta[c.strip()] = v.strip().strip('"').strip("'")
            texte = texte[fin + 3:]
    return meta, texte


def examiner(chemin):
    meta, corps = lire(chemin)
    nom = meta.get("name", os.path.basename(os.path.dirname(chemin)))
    try:
        confiance = float(meta.get("confidence", 0))
    except ValueError:
        confiance = 0.0
    statut = meta.get("status", "?")

    procedure = corps
    if "## Procedure" in corps:
        procedure = corps.split("## Procedure", 1)[1]

    outils_cites = sorted(o for o in OUTILS if re.search(rf"\b{re.escape(o)}\b", procedure))
    ressemble_a_du_code = bool(CODE.search(procedure))

    alertes = []
    if not outils_cites:
        alertes.append("ne nomme aucun outil : decrit un raisonnement, pas une action")
    if ressemble_a_du_code and not outils_cites:
        alertes.append("contient du code a ecrire plutot qu'un appel d'outil")
    if confiance >= 0.85 and statut == "draft":
        alertes.append(f"brouillon reinjecte quand meme (confiance {confiance} >= seuil)")
    if re.search(r"['\"]/(app|home|mnt)/[\w/.-]+['\"]", procedure):
        alertes.append("chemin absolu en dur : ne se generalisera pas")

    return nom, statut, confiance, outils_cites, alertes


def main():
    if not os.path.isdir(RACINE):
        print(f"Dossier introuvable : {RACINE}")
        return 1

    fichiers = []
    for base, _, noms in os.walk(RACINE):
        fichiers += [os.path.join(base, n) for n in noms if n == "SKILL.md"]

    if not fichiers:
        print("Aucune competence apprise pour l'instant.")
        print("L'agent en ecrit une quand il mene une tache a bien avec assez de confiance.")
        return 0

    print(f"{len(fichiers)} competence(s)\n")
    suspectes = 0
    for f in sorted(fichiers):
        nom, statut, conf, outils, alertes = examiner(f)
        marque = "!!" if alertes else "ok"
        print(f"[{marque}] {nom}   (statut {statut}, confiance {conf})")
        print(f"     outils cites : {', '.join(outils) if outils else 'aucun'}")
        for a in alertes:
            print(f"     -> {a}")
        print(f"     {os.path.relpath(f, RACINE)}")
        print()
        if alertes:
            suspectes += 1

    if suspectes:
        print(f"{suspectes} competence(s) a revoir.")
        print("Supprimer un dossier de competence suffit a l'oublier ; penser aussi")
        print("a retirer son entree de data/skills/_usage.json.")
    else:
        print("Rien a signaler : chaque procedure nomme les outils qu'elle emploie.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
