# Infomaniak API spec (OpenAPI 3.1)

Spec officiel d'Infomaniak intégré au repo pour usage offline et stabilité de référence.

- **Fichier** : [`infomaniak_openapi.json`](./infomaniak_openapi.json) (~1.6 MB, 255 paths, dont 152 kDrive)
- **Source** : <https://developer.infomaniak.com/docs/api> — bouton "Download" sur le portail
- **License** : MIT (cf. champ `info.license` du JSON)
- **Mis à jour** : voir `git log -1 -- docs/api/infomaniak_openapi.json`

## Pourquoi le garder ici

1. **Pas de duplication** : on stocke le JSON officiel tel quel, jamais reformulé en doc maison.
2. **Référence stable** : la version du repo correspond au comportement attesté à un instant T (les tests `scripts/api_test*.sh` ont validé cette version).
3. **Offline** : le portail Infomaniak peut bouger, le spec local reste utilisable pour grep / introspection.

## Comment l'utiliser depuis le terminal

```bash
# Lister tous les endpoints kDrive
python3 -c "import json; print('\n'.join(sorted(p for p in json.load(open('docs/api/infomaniak_openapi.json'))['paths'] if 'drive' in p.lower())))"

# Inspecter une route précise
python3 -c "
import json
s = json.load(open('docs/api/infomaniak_openapi.json'))
op = s['paths']['/3/drive/{drive_id}/upload']['post']
print('summary:', op['summary'])
print('params:')
for p in op.get('parameters', []):
    print(f'  [{p[\"in\"]}] {p[\"name\"]} ({p[\"schema\"][\"type\"]}){\" REQUIRED\" if p.get(\"required\") else \"\"}')
"
```

## Garder à jour

⚠️ **Le spec évolue côté Infomaniak**. La règle :

- **Re-télécharger au minimum 1 fois par mois** (ou avant chaque feature qui touche l'API).
- **Toujours** re-télécharger avant un PR qui modifie le layer API.
- Si un comportement réel diverge du spec local, c'est probablement que le spec a évolué — re-télécharge.

### Procédure d'update (2 min)

```bash
./scripts/update_api_doc.sh
```

Le script :
1. Ouvre <https://developer.infomaniak.com/docs/api> dans ton navigateur
2. Te demande de cliquer "Download spec" (le fichier arrive comme `~/Downloads/infomaniak_api_<timestamp>.json`)
3. Récupère le plus récent et le copie dans `docs/api/infomaniak_openapi.json`
4. Affiche un diff résumé (nouveaux endpoints, endpoints supprimés)

Le script vérifie aussi la fraîcheur du spec local et te prévient s'il est ancien.
