SOURCES = force  photogate vernier.rb
DIR = /usr/bin/labpro

default:
	@echo "No compilation is required. Install the libraries as described in the README file, then do a 'make install'."

install:
	install -d $(DIR)
	install $(SOURCES) $(DIR)
	@echo "If you get 'Operation not permitted' errors when you run the software, see the README file."
