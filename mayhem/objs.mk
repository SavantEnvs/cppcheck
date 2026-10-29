# Extra make rule used with oss-fuzz/Makefile: build every object of the fuzz client without linking.
harness-objs: $(EXTOBJ) $(LIBOBJ) main.o type2.o
