.PHONY: all render preview glossary validate clean

QUARTO ?= quarto
PYTHON ?= python3

all: validate render

glossary:
	$(PYTHON) tools/gen-glossary.py

validate:
	$(PYTHON) tools/validate.py

render: validate glossary
	$(QUARTO) render

preview: glossary
	$(QUARTO) preview

clean:
	rm -rf _site .quarto
