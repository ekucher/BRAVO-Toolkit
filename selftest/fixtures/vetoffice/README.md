# Characterization-фікстури VetOffice (#486)

Знеособлені фікстури для фіксації чинної поведінки Discovery на
інсталяціях VetOffice. Усі імена, шляхи й адреси вигадані.

Файли тут — лише шаблони й дані. Інсталяцію матеріалізує harness
`ci/acceptance/Invoke-BRAVOVetOfficeFixtureCharacterization.ps1` у каталог
`-OutputRoot` поза комплектом (плейсхолдер `{{VETOFFICE_ROOT}}` → шлях
матеріалізованого кореня):

```powershell
.\ci\acceptance\Invoke-BRAVOVetOfficeFixtureCharacterization.ps1 -OutputRoot 'D:\EVIDENCE\vetoffice'
```

Trace-файли в CP1251 і заглушки `.mdz` генеруються під час матеріалізації.
Їх навмисно немає в репозиторії: `.gitattributes` нормалізує текстові файли
(`* text=auto eol=crlf`).

Висновки та прогалини описано в `docs/BRAVO_VETOFFICE_GAP_ANALYSIS.md`.
