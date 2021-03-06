# cython: profile=False

from cpython cimport PyObject, Py_INCREF, PyList_Check, PyTuple_Check

from khash cimport *
from numpy cimport *
from cpython cimport PyMem_Malloc, PyMem_Realloc, PyMem_Free

from util cimport _checknan
cimport util

import numpy as np
nan = np.nan

cdef extern from "numpy/npy_math.h":
    double NAN "NPY_NAN"

cimport cython
cimport numpy as cnp

cnp.import_array()
cnp.import_ufunc()

cdef int64_t iNaT = util.get_nat()
_SIZE_HINT_LIMIT = (1 << 20) + 7

cdef extern from "datetime.h":
    bint PyDateTime_Check(object o)
    void PyDateTime_IMPORT()

PyDateTime_IMPORT

cdef extern from "Python.h":
    int PySlice_Check(object)

cdef size_t _INIT_VEC_CAP = 32

cdef class ObjectVector:

    cdef:
        PyObject **data
        size_t n, m
        ndarray ao

    def __cinit__(self):
        self.n = 0
        self.m = _INIT_VEC_CAP
        self.ao = np.empty(_INIT_VEC_CAP, dtype=object)
        self.data = <PyObject**> self.ao.data

    def __len__(self):
        return self.n

    cdef inline append(self, object o):
        if self.n == self.m:
            self.m = max(self.m * 2, _INIT_VEC_CAP)
            self.ao.resize(self.m)
            self.data = <PyObject**> self.ao.data

        Py_INCREF(o)
        self.data[self.n] = <PyObject*> o
        self.n += 1

    def to_array(self):
        self.ao.resize(self.n)
        self.m = self.n
        return self.ao

ctypedef struct Int64VectorData:
    int64_t *data
    size_t n, m

ctypedef struct Float64VectorData:
    float64_t *data
    size_t n, m

ctypedef fused vector_data:
    Int64VectorData
    Float64VectorData

ctypedef fused sixty_four_bit_scalar:
    int64_t
    float64_t

cdef bint needs_resize(vector_data *data) nogil:
    return data.n == data.m

cdef void append_data(vector_data *data, sixty_four_bit_scalar x) nogil:

    # compile time specilization of the fused types
    # as the cross-product is generated, but we cannot assign float->int
    # the types that don't pass are pruned
    if (vector_data is Int64VectorData and sixty_four_bit_scalar is int64_t) or (
        vector_data is Float64VectorData and sixty_four_bit_scalar is float64_t):

        data.data[data.n] = x
        data.n += 1

cdef class Int64Vector:

    cdef:
        Int64VectorData *data
        ndarray ao

    def __cinit__(self):
        self.data = <Int64VectorData *>PyMem_Malloc(sizeof(Int64VectorData))
        if not self.data:
            raise MemoryError()
        self.data.n = 0
        self.data.m = _INIT_VEC_CAP
        self.ao = np.empty(self.data.m, dtype=np.int64)
        self.data.data = <int64_t*> self.ao.data

    cdef resize(self):
        self.data.m = max(self.data.m * 4, _INIT_VEC_CAP)
        self.ao.resize(self.data.m)
        self.data.data = <int64_t*> self.ao.data

    def __dealloc__(self):
        PyMem_Free(self.data)

    def __len__(self):
        return self.data.n

    def to_array(self):
        self.ao.resize(self.data.n)
        self.data.m = self.data.n
        return self.ao

    cdef inline void append(self, int64_t x):

        if needs_resize(self.data):
            self.resize()

        append_data(self.data, x)

cdef class Float64Vector:

    cdef:
        Float64VectorData *data
        ndarray ao

    def __cinit__(self):
        self.data = <Float64VectorData *>PyMem_Malloc(sizeof(Float64VectorData))
        if not self.data:
            raise MemoryError()
        self.data.n = 0
        self.data.m = _INIT_VEC_CAP
        self.ao = np.empty(self.data.m, dtype=np.float64)
        self.data.data = <float64_t*> self.ao.data

    cdef resize(self):
        self.data.m = max(self.data.m * 4, _INIT_VEC_CAP)
        self.ao.resize(self.data.m)
        self.data.data = <float64_t*> self.ao.data

    def __dealloc__(self):
        PyMem_Free(self.data)

    def __len__(self):
        return self.data.n

    def to_array(self):
        self.ao.resize(self.data.n)
        self.data.m = self.data.n
        return self.ao

    cdef inline void append(self, float64_t x):

        if needs_resize(self.data):
            self.resize()

        append_data(self.data, x)

cdef class HashTable:
    pass

cdef class StringHashTable(HashTable):
    cdef kh_str_t *table

    def __cinit__(self, int size_hint=1):
        self.table = kh_init_str()
        if size_hint is not None:
            kh_resize_str(self.table, size_hint)

    def __dealloc__(self):
        kh_destroy_str(self.table)

    cpdef get_item(self, object val):
        cdef khiter_t k
        k = kh_get_str(self.table, util.get_c_string(val))
        if k != self.table.n_buckets:
            return self.table.vals[k]
        else:
            raise KeyError(val)

    def get_iter_test(self, object key, Py_ssize_t iterations):
        cdef Py_ssize_t i, val
        for i in range(iterations):
            k = kh_get_str(self.table, util.get_c_string(key))
            if k != self.table.n_buckets:
                val = self.table.vals[k]

    cpdef set_item(self, object key, Py_ssize_t val):
        cdef:
            khiter_t k
            int ret = 0
            char* buf

        buf = util.get_c_string(key)

        k = kh_put_str(self.table, buf, &ret)
        self.table.keys[k] = key
        if kh_exist_str(self.table, k):
            self.table.vals[k] = val
        else:
            raise KeyError(key)

    def get_indexer(self, ndarray[object] values):
        cdef:
            Py_ssize_t i, n = len(values)
            ndarray[int64_t] labels = np.empty(n, dtype=np.int64)
            char *buf
            int64_t *resbuf = <int64_t*> labels.data
            khiter_t k
            kh_str_t *table = self.table

        for i in range(n):
            buf = util.get_c_string(values[i])
            k = kh_get_str(table, buf)
            if k != table.n_buckets:
                resbuf[i] = table.vals[k]
            else:
                resbuf[i] = -1
        return labels

    def unique(self, ndarray[object] values):
        cdef:
            Py_ssize_t i, n = len(values)
            int ret = 0
            object val
            char *buf
            khiter_t k
            ObjectVector uniques = ObjectVector()

        for i in range(n):
            val = values[i]
            buf = util.get_c_string(val)
            k = kh_get_str(self.table, buf)
            if k == self.table.n_buckets:
                kh_put_str(self.table, buf, &ret)
                uniques.append(val)

        return uniques.to_array()

    def factorize(self, ndarray[object] values):
        cdef:
            Py_ssize_t i, n = len(values)
            ndarray[int64_t] labels = np.empty(n, dtype=np.int64)
            dict reverse = {}
            Py_ssize_t idx, count = 0
            int ret = 0
            object val
            char *buf
            khiter_t k

        for i in range(n):
            val = values[i]
            buf = util.get_c_string(val)
            k = kh_get_str(self.table, buf)
            if k != self.table.n_buckets:
                idx = self.table.vals[k]
                labels[i] = idx
            else:
                k = kh_put_str(self.table, buf, &ret)
                # print 'putting %s, %s' % (val, count)

                self.table.vals[k] = count
                reverse[count] = val
                labels[i] = count
                count += 1

        return reverse, labels

cdef class Int64HashTable(HashTable):

    def __cinit__(self, size_hint=1):
        self.table = kh_init_int64()
        if size_hint is not None:
            kh_resize_int64(self.table, size_hint)

    def __len__(self):
        return self.table.size

    def __dealloc__(self):
        kh_destroy_int64(self.table)

    def __contains__(self, object key):
        cdef khiter_t k
        k = kh_get_int64(self.table, key)
        return k != self.table.n_buckets

    cpdef get_item(self, int64_t val):
        cdef khiter_t k
        k = kh_get_int64(self.table, val)
        if k != self.table.n_buckets:
            return self.table.vals[k]
        else:
            raise KeyError(val)

    def get_iter_test(self, int64_t key, Py_ssize_t iterations):
        cdef Py_ssize_t i, val=0
        for i in range(iterations):
            k = kh_get_int64(self.table, val)
            if k != self.table.n_buckets:
                val = self.table.vals[k]

    cpdef set_item(self, int64_t key, Py_ssize_t val):
        cdef:
            khiter_t k
            int ret = 0

        k = kh_put_int64(self.table, key, &ret)
        self.table.keys[k] = key
        if kh_exist_int64(self.table, k):
            self.table.vals[k] = val
        else:
            raise KeyError(key)

    @cython.boundscheck(False)
    def map(self, int64_t[:] keys, int64_t[:] values):
        cdef:
            Py_ssize_t i, n = len(values)
            int ret = 0
            int64_t key
            khiter_t k

        with nogil:
            for i in range(n):
                key = keys[i]
                k = kh_put_int64(self.table, key, &ret)
                self.table.vals[k] = <Py_ssize_t> values[i]

    @cython.boundscheck(False)
    def map_locations(self, ndarray[int64_t, ndim=1] values):
        cdef:
            Py_ssize_t i, n = len(values)
            int ret = 0
            int64_t val
            khiter_t k

        with nogil:
            for i in range(n):
                val = values[i]
                k = kh_put_int64(self.table, val, &ret)
                self.table.vals[k] = i

    @cython.boundscheck(False)
    def lookup(self, int64_t[:] values):
        cdef:
            Py_ssize_t i, n = len(values)
            int ret = 0
            int64_t val
            khiter_t k
            int64_t[:] locs = np.empty(n, dtype=np.int64)

        with nogil:
            for i in range(n):
                val = values[i]
                k = kh_get_int64(self.table, val)
                if k != self.table.n_buckets:
                    locs[i] = self.table.vals[k]
                else:
                    locs[i] = -1

        return np.asarray(locs)

    def factorize(self, ndarray[object] values):
        reverse = {}
        labels = self.get_labels(values, reverse, 0, 0)
        return reverse, labels

    @cython.boundscheck(False)
    def get_labels(self, int64_t[:] values, Int64Vector uniques,
                   Py_ssize_t count_prior, Py_ssize_t na_sentinel,
                   bint check_null=True):
        cdef:
            Py_ssize_t i, n = len(values)
            int64_t[:] labels
            Py_ssize_t idx, count = count_prior
            int ret = 0
            int64_t val
            khiter_t k
            Int64VectorData *ud

        labels = np.empty(n, dtype=np.int64)
        ud = uniques.data

        with nogil:
            for i in range(n):
                val = values[i]
                k = kh_get_int64(self.table, val)

                if check_null and val == iNaT:
                    labels[i] = na_sentinel
                    continue

                if k != self.table.n_buckets:
                    idx = self.table.vals[k]
                    labels[i] = idx
                else:
                    k = kh_put_int64(self.table, val, &ret)
                    self.table.vals[k] = count

                    if needs_resize(ud):
                        with gil:
                            uniques.resize()
                    append_data(ud, val)
                    labels[i] = count
                    count += 1

        return np.asarray(labels)

    @cython.boundscheck(False)
    def get_labels_groupby(self, int64_t[:] values):
        cdef:
            Py_ssize_t i, n = len(values)
            int64_t[:] labels
            Py_ssize_t idx, count = 0
            int ret = 0
            int64_t val
            khiter_t k
            Int64Vector uniques = Int64Vector()
            Int64VectorData *ud

        labels = np.empty(n, dtype=np.int64)
        ud = uniques.data

        with nogil:
            for i in range(n):
                val = values[i]

                # specific for groupby
                if val < 0:
                    labels[i] = -1
                    continue

                k = kh_get_int64(self.table, val)
                if k != self.table.n_buckets:
                    idx = self.table.vals[k]
                    labels[i] = idx
                else:
                    k = kh_put_int64(self.table, val, &ret)
                    self.table.vals[k] = count

                    if needs_resize(ud):
                        with gil:
                            uniques.resize()
                    append_data(ud, val)
                    labels[i] = count
                    count += 1

        arr_uniques = uniques.to_array()

        return np.asarray(labels), arr_uniques

    @cython.boundscheck(False)
    def unique(self, int64_t[:] values):
        cdef:
            Py_ssize_t i, n = len(values)
            int ret = 0
            int64_t val
            khiter_t k
            Int64Vector uniques = Int64Vector()
            Int64VectorData *ud

        ud = uniques.data

        with nogil:
            for i in range(n):
                val = values[i]
                k = kh_get_int64(self.table, val)
                if k == self.table.n_buckets:
                    kh_put_int64(self.table, val, &ret)

                    if needs_resize(ud):
                        with gil:
                            uniques.resize()
                    append_data(ud, val)

        return uniques.to_array()


cdef class Float64HashTable(HashTable):

    def __cinit__(self, size_hint=1):
        self.table = kh_init_float64()
        if size_hint is not None:
            kh_resize_float64(self.table, size_hint)

    def __len__(self):
        return self.table.size

    cpdef get_item(self, float64_t val):
        cdef khiter_t k
        k = kh_get_float64(self.table, val)
        if k != self.table.n_buckets:
            return self.table.vals[k]
        else:
            raise KeyError(val)

    cpdef set_item(self, float64_t key, Py_ssize_t val):
        cdef:
            khiter_t k
            int ret = 0

        k = kh_put_float64(self.table, key, &ret)
        self.table.keys[k] = key
        if kh_exist_float64(self.table, k):
            self.table.vals[k] = val
        else:
            raise KeyError(key)

    def __dealloc__(self):
        kh_destroy_float64(self.table)

    def __contains__(self, object key):
        cdef khiter_t k
        k = kh_get_float64(self.table, key)
        return k != self.table.n_buckets

    def factorize(self, float64_t[:] values):
        uniques = Float64Vector()
        labels = self.get_labels(values, uniques, 0, -1, 1)
        return uniques.to_array(), labels

    @cython.boundscheck(False)
    def get_labels(self, float64_t[:] values,
                   Float64Vector uniques,
                   Py_ssize_t count_prior, int64_t na_sentinel,
                   bint check_null=True):
        cdef:
            Py_ssize_t i, n = len(values)
            int64_t[:] labels
            Py_ssize_t idx, count = count_prior
            int ret = 0
            float64_t val
            khiter_t k
            Float64VectorData *ud

        labels = np.empty(n, dtype=np.int64)
        ud = uniques.data

        with nogil:
            for i in range(n):
                val = values[i]

                if check_null and val != val:
                    labels[i] = na_sentinel
                    continue

                k = kh_get_float64(self.table, val)
                if k != self.table.n_buckets:
                    idx = self.table.vals[k]
                    labels[i] = idx
                else:
                    k = kh_put_float64(self.table, val, &ret)
                    self.table.vals[k] = count

                    if needs_resize(ud):
                        with gil:
                            uniques.resize()
                    append_data(ud, val)
                    labels[i] = count
                    count += 1

        return np.asarray(labels)

    @cython.boundscheck(False)
    def map_locations(self, ndarray[float64_t, ndim=1] values):
        cdef:
            Py_ssize_t i, n = len(values)
            int ret = 0
            khiter_t k

        with nogil:
            for i in range(n):
                k = kh_put_float64(self.table, values[i], &ret)
                self.table.vals[k] = i

    @cython.boundscheck(False)
    def lookup(self, float64_t[:] values):
        cdef:
            Py_ssize_t i, n = len(values)
            int ret = 0
            float64_t val
            khiter_t k
            int64_t[:] locs = np.empty(n, dtype=np.int64)

        with nogil:
            for i in range(n):
                val = values[i]
                k = kh_get_float64(self.table, val)
                if k != self.table.n_buckets:
                    locs[i] = self.table.vals[k]
                else:
                    locs[i] = -1

        return np.asarray(locs)

    @cython.boundscheck(False)
    def unique(self, float64_t[:] values):
        cdef:
            Py_ssize_t i, n = len(values)
            int ret = 0
            float64_t val
            khiter_t k
            bint seen_na = 0
            Float64Vector uniques = Float64Vector()
            Float64VectorData *ud

        ud = uniques.data

        with nogil:
            for i in range(n):
                val = values[i]

                if val == val:
                    k = kh_get_float64(self.table, val)
                    if k == self.table.n_buckets:
                        kh_put_float64(self.table, val, &ret)

                        if needs_resize(ud):
                            with gil:
                                uniques.resize()
                        append_data(ud, val)

                elif not seen_na:
                    seen_na = 1

                    if needs_resize(ud):
                        with gil:
                            uniques.resize()
                    append_data(ud, NAN)

        return uniques.to_array()

na_sentinel = object

cdef class PyObjectHashTable(HashTable):

    def __init__(self, size_hint=1):
        self.table = kh_init_pymap()
        kh_resize_pymap(self.table, size_hint)

    def __dealloc__(self):
        if self.table is not NULL:
            self.destroy()

    def __len__(self):
        return self.table.size

    def __contains__(self, object key):
        cdef khiter_t k
        hash(key)
        if key != key or key is None:
             key = na_sentinel
        k = kh_get_pymap(self.table, <PyObject*>key)
        return k != self.table.n_buckets

    def destroy(self):
        kh_destroy_pymap(self.table)
        self.table = NULL

    cpdef get_item(self, object val):
        cdef khiter_t k
        if val != val or val is None:
            val = na_sentinel
        k = kh_get_pymap(self.table, <PyObject*>val)
        if k != self.table.n_buckets:
            return self.table.vals[k]
        else:
            raise KeyError(val)

    def get_iter_test(self, object key, Py_ssize_t iterations):
        cdef Py_ssize_t i, val
        if key != key or key is None:
             key = na_sentinel
        for i in range(iterations):
            k = kh_get_pymap(self.table, <PyObject*>key)
            if k != self.table.n_buckets:
                val = self.table.vals[k]

    cpdef set_item(self, object key, Py_ssize_t val):
        cdef:
            khiter_t k
            int ret = 0
            char* buf

        hash(key)
        if key != key or key is None:
             key = na_sentinel
        k = kh_put_pymap(self.table, <PyObject*>key, &ret)
        # self.table.keys[k] = key
        if kh_exist_pymap(self.table, k):
            self.table.vals[k] = val
        else:
            raise KeyError(key)

    def map_locations(self, ndarray[object] values):
        cdef:
            Py_ssize_t i, n = len(values)
            int ret = 0
            object val
            khiter_t k

        for i in range(n):
            val = values[i]
            hash(val)
            if val != val or val is None:
                val = na_sentinel

            k = kh_put_pymap(self.table, <PyObject*>val, &ret)
            self.table.vals[k] = i

    def lookup(self, ndarray[object] values):
        cdef:
            Py_ssize_t i, n = len(values)
            int ret = 0
            object val
            khiter_t k
            int64_t[:] locs = np.empty(n, dtype=np.int64)

        for i in range(n):
            val = values[i]
            hash(val)
            if val != val or val is None:
                val = na_sentinel

            k = kh_get_pymap(self.table, <PyObject*>val)
            if k != self.table.n_buckets:
                locs[i] = self.table.vals[k]
            else:
                locs[i] = -1

        return np.asarray(locs)

    def unique(self, ndarray[object] values):
        cdef:
            Py_ssize_t i, n = len(values)
            int ret = 0
            object val
            khiter_t k
            ObjectVector uniques = ObjectVector()
            bint seen_na = 0

        for i in range(n):
            val = values[i]
            hash(val)
            if not _checknan(val):
                k = kh_get_pymap(self.table, <PyObject*>val)
                if k == self.table.n_buckets:
                    kh_put_pymap(self.table, <PyObject*>val, &ret)
                    uniques.append(val)
            elif not seen_na:
                seen_na = 1
                uniques.append(nan)

        return uniques.to_array()

    def get_labels(self, ndarray[object] values, ObjectVector uniques,
                   Py_ssize_t count_prior, int64_t na_sentinel,
                   bint check_null=True):
        cdef:
            Py_ssize_t i, n = len(values)
            int64_t[:] labels
            Py_ssize_t idx, count = count_prior
            int ret = 0
            object val
            khiter_t k

        labels = np.empty(n, dtype=np.int64)

        for i in range(n):
            val = values[i]
            hash(val)

            if check_null and val != val or val is None:
                labels[i] = na_sentinel
                continue

            k = kh_get_pymap(self.table, <PyObject*>val)
            if k != self.table.n_buckets:
                idx = self.table.vals[k]
                labels[i] = idx
            else:
                k = kh_put_pymap(self.table, <PyObject*>val, &ret)
                self.table.vals[k] = count
                uniques.append(val)
                labels[i] = count
                count += 1

        return np.asarray(labels)


cdef class Factorizer:
    cdef public PyObjectHashTable table
    cdef public ObjectVector uniques
    cdef public Py_ssize_t count

    def __init__(self, size_hint):
        self.table = PyObjectHashTable(size_hint)
        self.uniques = ObjectVector()
        self.count = 0

    def get_count(self):
        return self.count

    def factorize(self, ndarray[object] values, sort=False, na_sentinel=-1,
                  check_null=True):
        """
        Factorize values with nans replaced by na_sentinel
        >>> factorize(np.array([1,2,np.nan], dtype='O'), na_sentinel=20)
        array([ 0,  1, 20])
        """
        labels = self.table.get_labels(values, self.uniques,
                                       self.count, na_sentinel, check_null)
        mask = (labels == na_sentinel)
        # sort on
        if sort:
            if labels.dtype != np.int_:
                labels = labels.astype(np.int_)
            sorter = self.uniques.to_array().argsort()
            reverse_indexer = np.empty(len(sorter), dtype=np.int_)
            reverse_indexer.put(sorter, np.arange(len(sorter)))
            labels = reverse_indexer.take(labels, mode='clip')
            labels[mask] = na_sentinel
        self.count = len(self.uniques)
        return labels

    def unique(self, ndarray[object] values):
        # just for fun
        return self.table.unique(values)


cdef class Int64Factorizer:
    cdef public Int64HashTable table
    cdef public Int64Vector uniques
    cdef public Py_ssize_t count

    def __init__(self, size_hint):
        self.table = Int64HashTable(size_hint)
        self.uniques = Int64Vector()
        self.count = 0

    def get_count(self):
        return self.count

    def factorize(self, int64_t[:] values, sort=False,
                  na_sentinel=-1, check_null=True):
        labels = self.table.get_labels(values, self.uniques,
                                       self.count, na_sentinel,
                                       check_null)

        # sort on
        if sort:
            if labels.dtype != np.int_:
                labels = labels.astype(np.int_)

            sorter = self.uniques.to_array().argsort()
            reverse_indexer = np.empty(len(sorter), dtype=np.int_)
            reverse_indexer.put(sorter, np.arange(len(sorter)))

            labels = reverse_indexer.take(labels)

        self.count = len(self.uniques)
        return labels

ctypedef fused kh_scalar64:
    kh_int64_t
    kh_float64_t

@cython.boundscheck(False)
cdef build_count_table_scalar64(sixty_four_bit_scalar[:] values,
                                kh_scalar64 *table, bint dropna):
    cdef:
        khiter_t k
        Py_ssize_t i, n = len(values)
        sixty_four_bit_scalar val
        int ret = 0

    if sixty_four_bit_scalar is float64_t and kh_scalar64 is kh_float64_t:
        with nogil:
            kh_resize_float64(table, n)

            for i in range(n):
                val = values[i]
                if val == val or not dropna:
                    k = kh_get_float64(table, val)
                    if k != table.n_buckets:
                        table.vals[k] += 1
                    else:
                        k = kh_put_float64(table, val, &ret)
                        table.vals[k] = 1
    elif sixty_four_bit_scalar is int64_t and kh_scalar64 is kh_int64_t:
        with nogil:
            kh_resize_int64(table, n)

            for i in range(n):
                val = values[i]
                k = kh_get_int64(table, val)
                if k != table.n_buckets:
                    table.vals[k] += 1
                else:
                    k = kh_put_int64(table, val, &ret)
                    table.vals[k] = 1
    else:
        raise ValueError("Table type must match scalar type.")



@cython.boundscheck(False)
cpdef value_count_scalar64(sixty_four_bit_scalar[:] values, bint dropna):
    cdef:
        Py_ssize_t i
        kh_float64_t *ftable
        kh_int64_t *itable
        sixty_four_bit_scalar[:] result_keys
        int64_t[:] result_counts
        int k

    i = 0

    if sixty_four_bit_scalar is float64_t:
        ftable = kh_init_float64()
        build_count_table_scalar64(values, ftable, dropna)

        result_keys = np.empty(ftable.n_occupied, dtype=np.float64)
        result_counts = np.zeros(ftable.n_occupied, dtype=np.int64)

        with nogil:
            for k in range(ftable.n_buckets):
                if kh_exist_float64(ftable, k):
                    result_keys[i] = ftable.keys[k]
                    result_counts[i] = ftable.vals[k]
                    i += 1
        kh_destroy_float64(ftable)

    elif sixty_four_bit_scalar is int64_t:
        itable = kh_init_int64()
        build_count_table_scalar64(values, itable, dropna)

        result_keys = np.empty(itable.n_occupied, dtype=np.int64)
        result_counts = np.zeros(itable.n_occupied, dtype=np.int64)

        with nogil:
            for k in range(itable.n_buckets):
                if kh_exist_int64(itable, k):
                    result_keys[i] = itable.keys[k]
                    result_counts[i] = itable.vals[k]
                    i += 1
        kh_destroy_int64(itable)

    return np.asarray(result_keys), np.asarray(result_counts)


cdef build_count_table_object(ndarray[object] values,
                              ndarray[uint8_t, cast=True] mask,
                              kh_pymap_t *table):
    cdef:
        khiter_t k
        Py_ssize_t i, n = len(values)
        int ret = 0

    kh_resize_pymap(table, n // 10)

    for i in range(n):
        if mask[i]:
            continue

        val = values[i]
        k = kh_get_pymap(table, <PyObject*> val)
        if k != table.n_buckets:
            table.vals[k] += 1
        else:
            k = kh_put_pymap(table, <PyObject*> val, &ret)
            table.vals[k] = 1


cpdef value_count_object(ndarray[object] values,
                         ndarray[uint8_t, cast=True] mask):
    cdef:
        Py_ssize_t i
        kh_pymap_t *table
        int k

    table = kh_init_pymap()
    build_count_table_object(values, mask, table)

    i = 0
    result_keys = np.empty(table.n_occupied, dtype=object)
    result_counts = np.zeros(table.n_occupied, dtype=np.int64)
    for k in range(table.n_buckets):
        if kh_exist_pymap(table, k):
            result_keys[i] = <object> table.keys[k]
            result_counts[i] = table.vals[k]
            i += 1
    kh_destroy_pymap(table)

    return result_keys, result_counts


def mode_object(ndarray[object] values, ndarray[uint8_t, cast=True] mask):
    cdef:
        int count, max_count = 2
        int j = -1 # so you can do +=
        int k
        ndarray[object] modes
        kh_pymap_t *table

    table = kh_init_pymap()
    build_count_table_object(values, mask, table)

    modes = np.empty(table.n_buckets, dtype=np.object_)
    for k in range(table.n_buckets):
        if kh_exist_pymap(table, k):
            count = table.vals[k]

            if count == max_count:
                j += 1
            elif count > max_count:
                max_count = count
                j = 0
            else:
                continue
            modes[j] = <object> table.keys[k]

    kh_destroy_pymap(table)

    return modes[:j+1]


@cython.boundscheck(False)
def mode_int64(int64_t[:] values):
    cdef:
        int count, max_count = 2
        int j = -1 # so you can do +=
        int k
        kh_int64_t *table
        ndarray[int64_t] modes

    table = kh_init_int64()

    build_count_table_scalar64(values, table, 0)

    modes = np.empty(table.n_buckets, dtype=np.int64)

    with nogil:
        for k in range(table.n_buckets):
            if kh_exist_int64(table, k):
                count = table.vals[k]

                if count == max_count:
                    j += 1
                elif count > max_count:
                    max_count = count
                    j = 0
                else:
                    continue
                modes[j] = table.keys[k]

    kh_destroy_int64(table)

    return modes[:j+1]


def duplicated_object(ndarray[object] values, object keep='first'):
    cdef:
        Py_ssize_t i, n
        dict seen = dict()
        object row

    n = len(values)
    cdef ndarray[uint8_t] result = np.zeros(n, dtype=np.uint8)

    if keep == 'last':
        for i from n > i >= 0:
            row = values[i]
            if row in seen:
                result[i] = 1
            else:
                seen[row] = i
                result[i] = 0
    elif keep == 'first':
        for i from 0 <= i < n:
            row = values[i]
            if row in seen:
                result[i] = 1
            else:
                seen[row] = i
                result[i] = 0
    elif keep is False:
        for i from 0 <= i < n:
            row = values[i]
            if row in seen:
                result[i] = 1
                result[seen[row]] = 1
            else:
                seen[row] = i
                result[i] = 0
    else:
        raise ValueError('keep must be either "first", "last" or False')

    return result.view(np.bool_)


@cython.wraparound(False)
@cython.boundscheck(False)
def duplicated_float64(ndarray[float64_t, ndim=1] values,
                       object keep='first'):
    cdef:
        int ret = 0, k
        float64_t value
        Py_ssize_t i, n = len(values)
        kh_float64_t * table = kh_init_float64()
        ndarray[uint8_t, ndim=1, cast=True] out = np.empty(n, dtype='bool')

    kh_resize_float64(table, min(n, _SIZE_HINT_LIMIT))

    if keep not in ('last', 'first', False):
        raise ValueError('keep must be either "first", "last" or False')

    if keep == 'last':
        with nogil:
            for i from n > i >=0:
                kh_put_float64(table, values[i], &ret)
                out[i] = ret == 0
    elif keep == 'first':
        with nogil:
            for i from 0 <= i < n:
                kh_put_float64(table, values[i], &ret)
                out[i] = ret == 0
    else:
        with nogil:
            for i from 0 <= i < n:
                value = values[i]
                k = kh_get_float64(table, value)
                if k != table.n_buckets:
                    out[table.vals[k]] = 1
                    out[i] = 1
                else:
                    k = kh_put_float64(table, value, &ret)
                    table.keys[k] = value
                    table.vals[k] = i
                    out[i] = 0
    kh_destroy_float64(table)
    return out


@cython.wraparound(False)
@cython.boundscheck(False)
def duplicated_int64(ndarray[int64_t, ndim=1] values,
                     object keep='first'):
    cdef:
        int ret = 0, k
        int64_t value
        Py_ssize_t i, n = len(values)
        kh_int64_t * table = kh_init_int64()
        ndarray[uint8_t, ndim=1, cast=True] out = np.empty(n, dtype='bool')

    kh_resize_int64(table, min(n, _SIZE_HINT_LIMIT))

    if keep not in ('last', 'first', False):
        raise ValueError('keep must be either "first", "last" or False')

    if keep == 'last':
        with nogil:
            for i from n > i >=0:
                kh_put_int64(table, values[i], &ret)
                out[i] = ret == 0
    elif keep == 'first':
        with nogil:
            for i from 0 <= i < n:
                kh_put_int64(table, values[i], &ret)
                out[i] = ret == 0
    else:
        with nogil:
            for i from 0 <= i < n:
                value = values[i]
                k = kh_get_int64(table, value)
                if k != table.n_buckets:
                    out[table.vals[k]] = 1
                    out[i] = 1
                else:
                    k = kh_put_int64(table, value, &ret)
                    table.keys[k] = value
                    table.vals[k] = i
                    out[i] = 0
    kh_destroy_int64(table)
    return out


@cython.wraparound(False)
@cython.boundscheck(False)
def unique_label_indices(ndarray[int64_t, ndim=1] labels):
    """
    indices of the first occurrences of the unique labels
    *excluding* -1. equivelent to:
        np.unique(labels, return_index=True)[1]
    """
    cdef:
        int ret = 0
        Py_ssize_t i, n = len(labels)
        kh_int64_t * table = kh_init_int64()
        Int64Vector idx = Int64Vector()
        ndarray[int64_t, ndim=1] arr
        Int64VectorData *ud = idx.data

    kh_resize_int64(table, min(n, _SIZE_HINT_LIMIT))

    with nogil:
        for i in range(n):
            kh_put_int64(table, labels[i], &ret)
            if ret != 0:
                if needs_resize(ud):
                    with gil:
                        idx.resize()
                append_data(ud, i)

    kh_destroy_int64(table)

    arr = idx.to_array()
    arr = arr[labels[arr].argsort()]

    return arr[1:] if arr.size != 0 and labels[arr[0]] == -1 else arr
