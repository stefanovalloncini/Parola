let searchEqualityGolden = #"""
# sprint
a1|1|1|3.5/1/515|40+6|…lorem ipsum dolor sit amet consectetur Sprint planning, then budget review; the…
a2|1|1|1.0/0/48|36+6|…parlato della pianificazione dello sprint e del budget. È andata bene! Perché no?
a3|1|1|-|41+6|…war gesperrt, Größe spielt keine Rolle. Sprint-Planung und Budget: später.
a8|1|2|0.0/0/17|17+6,55+6|First line about sprint.

Second   paragraph	about the sprint…
# sprint planning
a1|2|2|3.5/1/515|40+6,47+8|…lorem ipsum dolor sit amet consectetur Sprint planning, then budget review; the…
a8|2|3|0.0/0/17|17+6,55+6|First line about sprint.

Second   paragraph	about the sprint…
a2|1|1|1.0/0/48|36+6|…parlato della pianificazione dello sprint e del budget. È andata bene! Perché no?
a3|1|1|-|41+6|…war gesperrt, Größe spielt keine Rolle. Sprint-Planung und Budget: später.
a5|1|1|-|38+8|…dolor sit amet consectetur plan plan planning planned
# plan
a5|3|4|-|40+4,45+4,50+4,59+4|…lorem ipsum dolor sit amet consectetur plan plan planning planned
a1|1|1|41.25/2/522|41+4|…ipsum dolor sit amet consectetur Sprint planning, then budget review; the budget was…
a3|1|1|-|34+4|…Größe spielt keine Rolle. Sprint-Planung und Budget: später.
a7|1|1|-||   
a8|1|1|12.0/1/73|41+4|…  paragraph	about the sprint review and planning.
# pla
a5|3|4|-|40+3,45+3,50+3,59+3|…lorem ipsum dolor sit amet consectetur plan plan planning planned
a1|1|1|41.25/2/522|41+3|…ipsum dolor sit amet consectetur Sprint planning, then budget review; the budget…
a3|1|1|-|34+3|…Größe spielt keine Rolle. Sprint-Planung und Budget: später.
a7|1|1|-||   
a8|1|1|12.0/1/73|41+3|…  paragraph	about the sprint review and planning.
# budget
a1|2|3|41.25/2/537|40+6,59+6|…amet consectetur Sprint planning, then budget review; the budget was fine.
a2|2|2|9.0/1/61|41+6|…della pianificazione dello sprint e del budget. È andata bene! Perché no?
a3|2|2|-|40+6|…spielt keine Rolle. Sprint-Planung und Budget: später.
a5|2|4|-|1+6,34+6|"Budget," he said -- (really?) -- budget...…
a6|2|2|-|0+6|budget
a4|1|1|-||我们讨论了预算和计划。Sprint 计划 next week, 预算 approved.
a7|1|1|-||   
a8|1|1|-||First line about sprint.

Second   paragraph	about the sprint review and…
# bud
a1|2|3|41.25/2/537|40+3,59+3|…amet consectetur Sprint planning, then budget review; the budget was fine.
a2|2|2|9.0/1/61|41+3|…della pianificazione dello sprint e del budget. È andata bene! Perché no?
a3|2|2|-|40+3|…spielt keine Rolle. Sprint-Planung und Budget: später.
a5|2|4|-|1+3,34+3|"Budget," he said -- (really?) -- budget...…
a6|2|2|-|0+3|budget
a4|1|1|-||我们讨论了预算和计划。Sprint 计划 next week, 预算 approved.
a7|1|1|-||   
a8|1|1|-||First line about sprint.

Second   paragraph	about the sprint review and…
# café
a1|1|2|0.0/0/6|6+4|Naïve café owners discussed the résumé of Zoë.…
# cafe
# résumé
a1|1|2|0.0/0/32|32+6|Naïve café owners discussed the résumé of Zoë. lorem ipsum dolor sit amet…
# naïve
a1|1|1|0.0/0/0|0+5|Naïve café owners discussed the résumé of…
# pianificazione
a2|1|2|1.0/0/27|27+14|Oggi abbiamo parlato della pianificazione dello sprint e del budget. È andata…
# pian
a2|1|2|1.0/0/27|27+4|Oggi abbiamo parlato della pianificazione dello sprint e del budget. È…
# straße
a3|1|1|-|4+6|Die Straße war gesperrt, Größe spielt keine Rolle.…
# größe
a3|1|1|-|25+5|Die Straße war gesperrt, Größe spielt keine Rolle. Sprint-Planung und…
# 预算
a4|1|1|0.0/0/32|5+2,32+2|我们讨论了预算和计划。Sprint 计划 next week, 预算 approved.
# 计划
a4|1|1|0.0/0/18|8+2,18+2|我们讨论了预算和计划。Sprint 计划 next week, 预算 approved.
# Zoë
a1|1|1|0.0/0/42|37+3|…café owners discussed the résumé of Zoë. lorem ipsum dolor sit amet consectetur…
# planning budget
a1|3|4|41.25/2/522|41+8,56+6,75+6|…ipsum dolor sit amet consectetur Sprint planning, then budget review; the budget was…
a5|3|5|-|1+6,34+6|"Budget," he said -- (really?) -- budget...…
a2|2|2|9.0/1/61|41+6|…della pianificazione dello sprint e del budget. È andata bene! Perché no?
a3|2|2|-|40+6|…spielt keine Rolle. Sprint-Planung und Budget: später.
a6|2|2|-|0+6|budget
a8|2|2|12.0/1/73|41+8|…  paragraph	about the sprint review and planning.
a4|1|1|-||我们讨论了预算和计划。Sprint 计划 next week, 预算 approved.
a7|1|1|-||   
# paragraph about
a8|2|4|0.0/0/11|11+5,35+9,45+5|First line about sprint.

Second   paragraph	about the…
a1|1|1|-||Naïve café owners discussed the résumé of Zoë. lorem ipsum dolor sit amet…
a2|1|1|-||Oggi abbiamo parlato della pianificazione dello sprint e del budget. È andata…
a3|1|1|-||Die Straße war gesperrt, Größe spielt keine Rolle. Sprint-Planung und Budget:…
a4|1|1|-||我们讨论了预算和计划。Sprint 计划 next week, 预算 approved.
a5|1|1|-||"Budget," he said -- (really?) -- budget... budget! lorem ipsum dolor sit amet…
a6|1|1|-||budget
a7|1|1|-||   
# nomatchatall
# x
# second paragraph
a8|2|2|12.0/1/26|26+6,35+9|First line about sprint.

Second   paragraph	about the sprint review and…
# really
a5|1|1|-|22+6|"Budget," he said -- (really?) -- budget... budget! lorem ipsum…
# lorem
a1|1|12|0.0/0/47|37+5,76+5|…owners discussed the résumé of Zoë. lorem ipsum dolor sit amet consectetur lorem…
a5|1|24|-|40+5,79+5|…said -- (really?) -- budget... budget! lorem ipsum dolor sit amet consectetur lorem…
"""#
