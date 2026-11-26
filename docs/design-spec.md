# Runway — direction design (source de vérité partagée design + tech)

Runway = app macOS de barre de menus qui affiche la conso du forfait Claude (session 5 h, semaine, limite par modèle, crédits d'usage). Copie en français.

## Style : minimaliste, façon Vercel / Linear
- **Monochrome.** Aucun dégradé, aucun verre, aucun flou, aucun shimmer, aucun halo, aucune ombre colorée. La couleur n'apparaît que pour signaler un problème.
- **Surfaces pleines** + **bordures 1 px**. Hiérarchie par la typo et l'espacement, pas par des cartes empilées.
- Sombre (défaut, suit le système) : fond `#0A0A0A`, surface `#111111`, bordure `#262626`, texte `#EDEDED`, secondaire `#A1A1A1`, tertiaire `#8A8A8A`, piste de jauge `#262626`.
- Clair : fond `#FFFFFF`, surface `#FAFAFA`, bordure `#EAEAEA`, texte `#171717`, secondaire `#666666`, tertiaire `#767676`, piste `#EAEAEA`.
- Remplissage des jauges : couleur du texte (`#EDEDED` / `#171717`) sous 80 % ; ambre `#F5A524` dès 80 % ; rouge `#E5484D` dès 95 %. Couleur pleine, jamais de dégradé.
- Typo : SF Pro (texte) ; **chiffres en SF Mono**, tabulaires. Tailles : 13 pt corps, 12 pt secondaire, 11 pt labels. Graisse max semibold, pas de bold.
- Rayons : popover 12, contrôles 6, pastilles 4. Jauges : hauteur 4, rayon 2.
- Mouvement : seulement des transitions de 150 ms ease-out (ouverture, changement de valeur). L'icône de refresh peut tourner pendant le refresh, rien d'autre ne bouge.

## Popover (largeur 320 pt, padding 16, fond plein ; forme, bordure et ombre = panneau système)
1. **Header** (une ligne) : « Runway » semibold 13 pt + pastille plan « Max 5x » (bordure 1 px, texte secondaire 11 pt) ; à droite 2 boutons icône 24 pt sans fond (fond surface au survol) : rafraîchir, réglages. Ligne compte secondaire 11 pt « you@example.com · Team » (« Compte perso », « Entreprise »), puis sous-titre tertiaire 11 pt « Mis à jour il y a 8 s ».
2. Séparateur 1 px.
3. **Liste de jauges**, chaque ligne : label à gauche (secondaire 12 pt), valeur mono à droite (texte 13 pt), jauge 4 pt pleine largeur dessous, puis ligne meta tertiaire 11 pt.
   - « Session » `18%` — meta « Reset 17:10 · dans 4 h 23 » ; projection en dessous, secondaire : « À ce rythme : ~41 % au reset », ou en ambre si on tape le mur avant : « 100 % vers 16:08, 32 min avant le reset ».
   - « Semaine » `73%` — meta « Reset dim. 30 nov. 16:00 ».
   - « Semaine · Fable » `0%` (nom du modèle venant de l'API, limite scopée) — même meta.
4. Séparateur 1 px.
5. **Crédits d'usage** (si activés) : ligne label + valeur mono « 30,80 € / 30,00 € » ; si ≥ 100 % une pastille « Plafond atteint » texte rouge `#E5484D` sur fond rouge 10 %, bordure rouge 30 %.
6. Séparateur 1 px. **Footer** : « Détail sur claude.ai ↗ » et « Quitter », secondaires 12 pt, sans soulignement (soulignement au survol).
- Réglages (même popover, vue 2, flèche retour) : seuils notifs session 50/80/95 et semaine 50/80/95 en pastilles à bordure (active = fond texte, texte fond), affichage barre en contrôle segmenté à bordure (Session / Semaine / Les deux / Icône), switches monochromes « Prévenir quand la session est rechargée », « Ouvrir au démarrage du Mac ».
- États : token expiré (ligne d'alerte avec point ambre + texte), limite d'appels (429 : « Limite d'appels atteinte · reprise à 16:21 » en rouge, valeurs en cache en tertiaire, sinon une phrase « Claude limite la fréquence de lecture de la conso… » dans le corps), hors ligne (valeurs en tertiaire + « Hors ligne · il y a 12 min » en rouge `#E5484D`, medium), Claude Code absent (texte + commande `claude` en mono dans un encadré à bordure).

## Barre de menus
Texte mono « 18% » précédé d'une mini jauge horizontale 14×3 pt. Monochrome (template) sous 80 %, ambre ou rouge au-delà. En mode « Les deux » : « 18 · 73% ».

## Notifications (validées, ne pas changer le contenu)
« Session à 50 % / 80 % / 95 % », « Semaine à 80 % », « Session rechargée », « Connexion Claude Code expirée ». Une seule par seuil et par fenêtre, son à 95 % uniquement. Icône d'app : carré noir, mini jauge blanche, rien d'autre.
