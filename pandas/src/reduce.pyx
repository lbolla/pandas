from numpy cimport *
import numpy as np

cdef class Reducer:
    '''
    Performs generic reduction operation on a C or Fortran-contiguous ndarray
    while avoiding ndarray construction overhead
    '''
    cdef:
        Py_ssize_t increment, chunksize, nresults
        object arr, dummy, f, labels
        bint can_set_name

    def __init__(self, object arr, object f, axis=1, dummy=None,
                 labels=None):
        n, k = arr.shape

        if axis == 0:
            if not arr.flags.f_contiguous:
                arr = arr.copy('F')

            self.nresults = k
            self.chunksize = n
            self.increment = n * arr.dtype.itemsize
        else:
            if not arr.flags.c_contiguous:
                arr = arr.copy('C')

            self.nresults = n
            self.chunksize = k
            self.increment = k * arr.dtype.itemsize

        self.f = f
        self.arr = arr
        self.dummy = self._check_dummy(dummy)
        self.labels = labels

    def _check_dummy(self, dummy=None):
        if dummy is None:
            dummy = np.empty(self.chunksize, dtype=self.arr.dtype)
            self.can_set_name = 0
        else:
            if dummy.dtype != self.arr.dtype:
                raise ValueError('Dummy array must be same dtype')
            if len(dummy) != self.chunksize:
                raise ValueError('Dummy array must be length %d' %
                                 self.chunksize)
            self.can_set_name = type(dummy) != np.ndarray

        return dummy

    def get_result(self):
        cdef:
            char* dummy_buf
            ndarray arr, result, chunk
            Py_ssize_t i
            flatiter it
            object res
            bint set_label = 0
            ndarray labels

        arr = self.arr
        chunk = self.dummy

        dummy_buf = chunk.data
        chunk.data = arr.data

        set_label = self.labels is not None and self.can_set_name
        if set_label:
            labels = self.labels

        try:
            for i in range(self.nresults):
                if set_label:
                    chunk.name = util.get_value_at(labels, i)

                res = self.f(chunk)
                if i == 0:
                    result = self._get_result_array(res)
                    it = <flatiter> PyArray_IterNew(result)

                PyArray_SETITEM(result, PyArray_ITER_DATA(it), res)
                chunk.data = chunk.data + self.increment
                PyArray_ITER_NEXT(it)
        except Exception, e:
            if hasattr(e, 'args'):
                e.args = e.args + (i,)
            raise
        finally:
            # so we don't free the wrong memory
            chunk.data = dummy_buf

        if result.dtype == np.object_:
            result = maybe_convert_objects(result)

        return result

    def _get_result_array(self, object res):
        try:
            assert(not isinstance(res, np.ndarray))
            assert(not (isinstance(res, list) and len(res) == len(self.dummy)))

            result = np.empty(self.nresults, dtype='O')
            result[0] = res
        except Exception:
            raise ValueError('function does not reduce')
        return result

cdef class SeriesBinGrouper:
    '''
    Performs grouping operation according to bin edges, rather than labels
    '''
    cdef:
        Py_ssize_t nresults, ngroups
        bint passed_dummy

    cdef public:
        object arr, index, dummy, f, bins

    def __init__(self, object series, object f, object bins, object dummy):
        n = len(series)

        self.bins = bins
        self.f = f
        if not series.flags.c_contiguous:
            series = series.copy('C')
        self.arr = series
        self.index = series.index

        self.dummy = self._check_dummy(dummy)
        self.passed_dummy = dummy is not None

        # kludge for #1688
        if len(bins) > 0 and bins[-1] == len(series):
            self.ngroups = len(bins)
        else:
            self.ngroups = len(bins) + 1

    def _check_dummy(self, dummy=None):
        if dummy is None:
            dummy = np.empty(0, dtype=self.arr.dtype)
        else:
            if dummy.dtype != self.arr.dtype:
                raise ValueError('Dummy array must be same dtype')
            if not dummy.flags.contiguous:
                dummy = dummy.copy()

        return dummy

    def get_result(self):
        cdef:
            ndarray arr, result
            ndarray[int64_t] counts
            Py_ssize_t i, n, group_size
            object res, chunk
            bint initialized = 0
            Slider vslider, islider
            IndexEngine gin

        counts = np.zeros(self.ngroups, dtype=np.int64)

        if self.ngroups > 1:
            counts[0] = self.bins[0]
            for i in range(1, self.ngroups):
                if i == self.ngroups - 1:
                    counts[i] = len(self.arr) - self.bins[i-1]
                else:
                    counts[i] = self.bins[i] - self.bins[i-1]

        chunk = self.dummy
        group_size = 0
        n = len(self.arr)

        vslider = Slider(self.arr, self.dummy)
        islider = Slider(self.index, self.dummy.index)

        gin = <IndexEngine> self.dummy.index._engine

        try:
            for i in range(self.ngroups):
                group_size = counts[i]

                islider.set_length(group_size)
                vslider.set_length(group_size)

                res = self.f(chunk)

                if not initialized:
                    result = self._get_result_array(res)
                    initialized = 1

                util.assign_value_1d(result, i, res)

                islider.advance(group_size)
                vslider.advance(group_size)

                gin.clear_mapping()
        except:
            raise
        finally:
            # so we don't free the wrong memory
            islider.cleanup()
            vslider.cleanup()

        if result.dtype == np.object_:
            result = maybe_convert_objects(result)

        return result, counts

    def _get_result_array(self, object res):
        try:
            assert(not isinstance(res, np.ndarray))
            assert(not (isinstance(res, list) and len(res) == len(self.dummy)))

            result = np.empty(self.ngroups, dtype='O')
        except Exception:
            raise ValueError('function does not reduce')
        return result

cdef class SeriesGrouper:
    '''
    Performs generic grouping operation while avoiding ndarray construction
    overhead
    '''
    cdef:
        Py_ssize_t nresults, ngroups
        bint passed_dummy

    cdef public:
        object arr, index, dummy, f, labels

    def __init__(self, object series, object f, object labels,
                 Py_ssize_t ngroups, object dummy):
        n = len(series)

        self.labels = labels
        self.f = f
        if not series.flags.c_contiguous:
            series = series.copy('C')
        self.arr = series
        self.index = series.index

        self.dummy = self._check_dummy(dummy)
        self.passed_dummy = dummy is not None
        self.ngroups = ngroups

    def _check_dummy(self, dummy=None):
        if dummy is None:
            dummy = np.empty(0, dtype=self.arr.dtype)
        else:
            if dummy.dtype != self.arr.dtype:
                raise ValueError('Dummy array must be same dtype')
            if not dummy.flags.contiguous:
                dummy = dummy.copy()

        return dummy

    def get_result(self):
        cdef:
            ndarray arr, result
            ndarray[int64_t] labels, counts
            Py_ssize_t i, n, group_size, lab
            object res, chunk
            bint initialized = 0
            Slider vslider, islider
            IndexEngine gin

        labels = self.labels
        counts = np.zeros(self.ngroups, dtype=np.int64)
        chunk = self.dummy
        group_size = 0
        n = len(self.arr)

        vslider = Slider(self.arr, self.dummy)
        islider = Slider(self.index, self.dummy.index)

        gin = <IndexEngine> self.dummy.index._engine
        try:
            for i in range(n):
                group_size += 1

                lab = labels[i]

                if i == n - 1 or lab != labels[i + 1]:
                    if lab == -1:
                        islider.advance(group_size)
                        vslider.advance(group_size)
                        group_size = 0
                        continue

                    islider.set_length(group_size)
                    vslider.set_length(group_size)

                    res = self.f(chunk)

                    if not initialized:
                        result = self._get_result_array(res)
                        initialized = 1

                    util.assign_value_1d(result, lab, res)
                    counts[lab] = group_size
                    islider.advance(group_size)
                    vslider.advance(group_size)

                    group_size = 0

                    gin.clear_mapping()

        except:
            raise
        finally:
            # so we don't free the wrong memory
            islider.cleanup()
            vslider.cleanup()

        if result.dtype == np.object_:
            result = maybe_convert_objects(result)

        return result, counts

    def _get_result_array(self, object res):
        try:
            assert(not isinstance(res, np.ndarray))
            assert(not (isinstance(res, list) and len(res) == len(self.dummy)))

            result = np.empty(self.ngroups, dtype='O')
        except Exception:
            raise ValueError('function does not reduce')
        return result

cdef class Slider:
    '''
    Only handles contiguous data for now
    '''
    cdef:
        ndarray values, buf
        Py_ssize_t stride, orig_len
        char *orig_data

    def __init__(self, object values, object buf):
        assert(values.ndim == 1)
        if not values.flags.contiguous:
            values = values.copy()

        assert(values.dtype == buf.dtype)
        self.values = values
        self.buf = buf
        self.stride = values.dtype.itemsize

        self.orig_data = self.buf.data
        self.orig_len = self.buf.shape[0]

        self.buf.data = self.values.data

    cpdef advance(self, Py_ssize_t k):
        self.buf.data = <char*> self.buf.data + self.stride * k

    cpdef set_length(self, Py_ssize_t length):
        self.buf.shape[0] = length

    cpdef cleanup(self):
        self.buf.shape[0] = self.orig_len
        self.buf.data = self.orig_data

def reduce(arr, f, axis=0, dummy=None, labels=None):
    if labels._has_complex_internals:
        raise Exception('Cannot use shortcut')

    reducer = Reducer(arr, f, axis=axis, dummy=dummy, labels=labels)
    return reducer.get_result()
