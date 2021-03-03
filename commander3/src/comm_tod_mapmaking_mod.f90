!================================================================================
!
! Copyright (C) 2020 Institute of Theoretical Astrophysics, University of Oslo.
!
! This file is part of Commander3.
!
! Commander3 is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! Commander3 is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with Commander3. If not, see <https://www.gnu.org/licenses/>.
!
!================================================================================
module comm_tod_mapmaking_mod
   use comm_tod_mod
   use comm_utils
   use comm_shared_arr_mod
   use comm_map_mod
   implicit none

   type comm_binmap
      integer(i4b)       :: ncol, n_A, nout, nobs, npix, numprocs_shared, chunk_size
      logical(lgt)       :: shared, solve_S
      type(shared_2d_dp) :: sA_map
      type(shared_3d_dp) :: sb_map
      class(map_ptr), allocatable, dimension(:)     :: outmaps
      real(dp),       allocatable, dimension(:,:)   :: A_map
      real(dp),       allocatable, dimension(:,:,:) :: b_map
    contains
      procedure :: init    => init_binmap
      procedure :: dealloc => dealloc_binmap
      procedure :: synchronize => syncronize_binmap
   end type comm_binmap

contains

  subroutine init_binmap(self, tod, shared, solve_S)
    implicit none
    class(comm_binmap),  intent(inout) :: self
    class(comm_tod),     intent(in)    :: tod
    logical(lgt),        intent(in)    :: shared, solve_S

    integer(i4b) :: i, ierr

    self%nobs            = tod%nobs
    self%shared          = shared
    self%solve_S         = solve_S
    self%npix            = tod%info%npix
    self%numprocs_shared = tod%numprocs_shared
    self%chunk_size      = self%npix/self%numprocs_shared
    if (solve_S) then
       self%ncol = tod%nmaps + tod%ndet - 1
       self%n_A  = tod%nmaps*(tod%nmaps+1)/2 + 4*(tod%ndet-1)
       self%nout = tod%output_n_maps + size(tod%bp_delta,2) - 1
    else
       self%ncol = tod%nmaps
       self%n_A  = tod%nmaps*(tod%nmaps+1)/2
       self%nout = tod%output_n_maps
    end if
    allocate(self%outmaps(self%nout))
    do i = 1, self%nout
       self%outmaps(i)%p => comm_map(tod%info)
    end do
    allocate(self%A_map(self%n_A,self%nobs), self%b_map(self%nout,self%ncol,self%nobs))
    self%A_map = 0.d0; self%b_map = 0.d0
    if (self%shared) then
       call init_shared_2d_dp(tod%myid_shared, tod%comm_shared, &
            & tod%myid_inter, tod%comm_inter, [self%n_A,self%npix], self%sA_map)
       call mpi_win_fence(0, self%sA_map%win, ierr)
       if (self%sA_map%myid_shared == 0) self%sA_map%a = 0.d0
       call mpi_win_fence(0, self%sA_map%win, ierr)
       call init_shared_3d_dp(tod%myid_shared, tod%comm_shared, &
               & tod%myid_inter, tod%comm_inter, [self%nout,self%ncol,self%npix], self%sb_map)
       call mpi_win_fence(0, self%sb_map%win, ierr)
       if (self%sb_map%myid_shared == 0) self%sb_map%a = 0.d0
       call mpi_win_fence(0, self%sb_map%win, ierr)
    else

    end if

  end subroutine init_binmap


  subroutine dealloc_binmap(self)
    implicit none
    class(comm_binmap), intent(inout) :: self

    integer(i4b) ::  i

    if (allocated(self%A_map)) deallocate(self%A_map, self%b_map)
    if (self%sA_map%init)  call dealloc_shared_2d_dp(self%sA_map)
    if (self%sb_map%init)  call dealloc_shared_3d_dp(self%sb_map)
    if (allocated(self%outmaps)) then
       do i = 1, self%nout
          call self%outmaps(i)%p%dealloc
       end do
       deallocate(self%outmaps)
    end if

  end subroutine dealloc_binmap

  subroutine syncronize_binmap(self, tod)
    implicit none
    class(comm_binmap),  intent(inout) :: self
    class(comm_tod),     intent(in)    :: tod

    integer(i4b) :: i, j, start_chunk, end_chunk, ierr

    if (.not. self%shared) return

    do i = 0, self%numprocs_shared-1
       start_chunk = mod(self%sA_map%myid_shared+i,self%numprocs_shared)*self%chunk_size
       end_chunk   = min(start_chunk+self%chunk_size-1,self%npix-1)
       do while (start_chunk < self%npix)
          if (tod%pix2ind(start_chunk) /= -1) exit
          start_chunk = start_chunk+1
       end do
       do while (end_chunk >= start_chunk)
          if (tod%pix2ind(end_chunk) /= -1) exit
          end_chunk = end_chunk-1
       end do
       if (start_chunk < self%npix)  start_chunk = tod%pix2ind(start_chunk)
       if (end_chunk >= start_chunk) end_chunk   = tod%pix2ind(end_chunk)

       call mpi_win_fence(0, self%sA_map%win, ierr)
       call mpi_win_fence(0, self%sb_map%win, ierr)
       do j = start_chunk, end_chunk
          self%sA_map%a(:,tod%ind2pix(j)+1) = self%sA_map%a(:,tod%ind2pix(j)+1) + &
                  & self%A_map(:,j)
          self%sb_map%a(:,:,tod%ind2pix(j)+1) = self%sb_map%a(:,:,tod%ind2pix(j)+1) + &
                  & self%b_map(:,:,j)
       end do
    end do
    call mpi_win_fence(0, self%sA_map%win, ierr)
    call mpi_win_fence(0, self%sb_map%win, ierr)

  end subroutine syncronize_binmap

  ! Compute map with white noise assumption from correlated noise 
  ! corrected and calibrated data, d' = (d-n_corr-n_temp)/gain 
  subroutine bin_TOD(tod, scan, pix, psi, flag, data, binmap)
    implicit none
    class(comm_tod),                             intent(in)    :: tod
    integer(i4b),                                intent(in)    :: scan
    integer(i4b),        dimension(1:,1:),       intent(in)    :: pix, psi, flag
    real(sp),            dimension(1:,1:,1:),    intent(in)    :: data
    type(comm_binmap),                           intent(inout) :: binmap

    integer(i4b) :: det, i, t, pix_, off, nout, psi_
    real(dp)     :: inv_sigmasq

    nout = binmap%nout
    do det = 1, size(pix,2)
       if (.not. tod%scans(scan)%d(det)%accept) cycle
       off         = 6 + 4*(det-1)
       inv_sigmasq = (tod%scans(scan)%d(det)%gain/tod%scans(scan)%d(det)%sigma0)**2
       do t = 1, size(pix,1)
          
          if (iand(flag(t,det),tod%flag0) .ne. 0) cycle
          
          pix_    = tod%pix2ind(pix(t,det))
          psi_    = psi(t,det)
          
          binmap%A_map(1,pix_) = binmap%A_map(1,pix_) + 1.d0                                 * inv_sigmasq
          binmap%A_map(2,pix_) = binmap%A_map(2,pix_) + tod%cos2psi(psi_)                    * inv_sigmasq
          binmap%A_map(3,pix_) = binmap%A_map(3,pix_) + tod%cos2psi(psi_)**2                 * inv_sigmasq
          binmap%A_map(4,pix_) = binmap%A_map(4,pix_) + tod%sin2psi(psi_)                    * inv_sigmasq
          binmap%A_map(5,pix_) = binmap%A_map(5,pix_) + tod%cos2psi(psi_)*tod%sin2psi(psi_) * inv_sigmasq
          binmap%A_map(6,pix_) = binmap%A_map(6,pix_) + tod%sin2psi(psi_)**2                 * inv_sigmasq
          
          do i = 1, nout
             binmap%b_map(i,1,pix_) = binmap%b_map(i,1,pix_) + data(i,t,det)                      * inv_sigmasq
             binmap%b_map(i,2,pix_) = binmap%b_map(i,2,pix_) + data(i,t,det) * tod%cos2psi(psi_) * inv_sigmasq
             binmap%b_map(i,3,pix_) = binmap%b_map(i,3,pix_) + data(i,t,det) * tod%sin2psi(psi_) * inv_sigmasq
          end do
          
          if (binmap%solve_S .and. det < tod%ndet) then
             binmap%A_map(off+1,pix_) = binmap%A_map(off+1,pix_) + 1.d0               * inv_sigmasq 
             binmap%A_map(off+2,pix_) = binmap%A_map(off+2,pix_) + tod%cos2psi(psi_) * inv_sigmasq
             binmap%A_map(off+3,pix_) = binmap%A_map(off+3,pix_) + tod%sin2psi(psi_) * inv_sigmasq
             binmap%A_map(off+4,pix_) = binmap%A_map(off+4,pix_) + 1.d0               * inv_sigmasq
             do i = 1, nout
                binmap%b_map(i,det+3,pix_) = binmap%b_map(i,det+3,pix_) + data(i,t,det) * inv_sigmasq 
             end do
          end if
          
       end do
    end do

  end subroutine bin_TOD


   ! differential TOD computation, written with WMAP in mind.
   subroutine bin_differential_TOD(tod, data, pix, psi, flag, x_imarr, pmask, b, M_diag, scan, comp_S, b_mono)
      implicit none
      class(comm_tod), intent(in)                               :: tod
      integer(i4b), intent(in)                                  :: scan
      real(sp), dimension(1:, 1:, 1:), intent(in)               :: data
      integer(i4b), dimension(1:), intent(in)                   :: flag
      integer(i4b), dimension(0:), intent(in)                   :: pmask
      integer(i4b), dimension(1:, 1:), intent(in)               :: pix, psi
      real(dp), dimension(1:), intent(in)                       :: x_imarr
      real(dp), dimension(0:, 1:, 1:), intent(inout)            :: b
      real(dp), dimension(0:, 1:), intent(inout)                :: M_diag
      real(dp), dimension(0:, 1:, 1:), intent(inout), optional  :: b_mono
      logical(lgt), intent(in)                                  :: comp_S

      integer(i4b) :: det, i, t, nout
      real(dp)     :: inv_sigmasq, d, p, var, dx_im, x_im

      integer(i4b) :: lpix, rpix, lpsi, rpsi, sgn

      integer(i4b) :: pA, pB, f_A, f_B

      nout = size(b, dim=3)
      dx_im = 0.5*(x_imarr(1) - x_imarr(2))
      x_im = 0.5*(x_imarr(1) + x_imarr(2))

      if (tod%scans(scan)%d(1)%accept) then
         !inv_sigmasq = 0.d0 
         var = 0
         do det = 1, 4
           var = var  + (tod%scans(scan)%d(det)%sigma0/tod%scans(scan)%d(det)%gain)**2/4
           !inv_sigmasq = inv_sigmasq  + (tod%scans(scan)%d(det)%gain/tod%scans(scan)%d(det)%sigma0)**2
         end do
         inv_sigmasq = 1/var
         do t = 1, tod%scans(scan)%ntod
            if (flag(t) /= 0 .and. flag(t) /= 262144) cycle

            lpix = pix(t, 1)
            rpix = pix(t, 2)
            lpsi = psi(t, 1)
            rpsi = psi(t, 2)
            f_A = pmask(rpix)
            f_B = pmask(lpix)

            do i = 1, nout
               d = 0.d0
               p = 0.d0
               do det = 1, 4
                 !sgn = (-1)**((det + 1)/2 + 1) ! 1 for 13, 14, -1 for 23, 24
                 d = d + data(i, t, det)/4
                 p = p + data(i, t, det)/4*(-1)**((det + 1)/2 + 1)
               end do
               ! T
               b(lpix, 1, i) = b(lpix, 1, i) + f_A*((1.d0+x_im)*d + dx_im*p)*inv_sigmasq
               b(rpix, 1, i) = b(rpix, 1, i) - f_B*((1.d0-x_im)*d - dx_im*p)*inv_sigmasq
               ! Q
               b(lpix, 2, i) = b(lpix, 2, i) + f_A*((1.d0+x_im)*p + dx_im*d)*tod%cos2psi(lpsi)*inv_sigmasq
               b(rpix, 2, i) = b(rpix, 2, i) - f_B*((1.d0-x_im)*p - dx_im*d)*tod%cos2psi(rpsi)*inv_sigmasq
               ! U
               b(lpix, 3, i) = b(lpix, 3, i) + f_A*((1.d0+x_im)*p + dx_im*d)*tod%sin2psi(lpsi)*inv_sigmasq
               b(rpix, 3, i) = b(rpix, 3, i) - f_B*((1.d0-x_im)*p - dx_im*d)*tod%sin2psi(rpsi)*inv_sigmasq
            end do

            M_diag(lpix, 1) = M_diag(lpix, 1) + f_A*inv_sigmasq
            M_diag(rpix, 1) = M_diag(rpix, 1) + f_B*inv_sigmasq
            M_diag(lpix, 2) = M_diag(lpix, 2) + f_A*inv_sigmasq*tod%cos2psi(lpsi)**2
            M_diag(rpix, 2) = M_diag(rpix, 2) + f_B*inv_sigmasq*tod%cos2psi(rpsi)**2
            M_diag(lpix, 3) = M_diag(lpix, 3) + f_A*inv_sigmasq*tod%sin2psi(lpsi)**2
            M_diag(rpix, 3) = M_diag(rpix, 3) + f_B*inv_sigmasq*tod%sin2psi(rpsi)**2

            ! Not a true diagonal term, just the off-diagonal estimate of the
            ! covariance for each pixel.
            M_diag(lpix, 4) = M_diag(lpix, 4)+f_A*inv_sigmasq*tod%sin2psi(lpsi)*tod%cos2psi(lpsi)
            M_diag(rpix, 4) = M_diag(rpix, 4)+f_B*inv_sigmasq*tod%sin2psi(rpsi)*tod%cos2psi(rpsi)

         end do
       end if

end subroutine bin_differential_TOD

   subroutine compute_Ax(tod, x_imarr, pmask, x_in, y_out)
      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
      ! Code to compute matrix product P^T N^-1 P m
      ! y = Ax
      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
      implicit none
      class(comm_tod),                 intent(in)              :: tod
      real(dp),     dimension(1:),     intent(in)              :: x_imarr
      integer(i4b), dimension(0:),     intent(in)              :: pmask
      real(dp),     dimension(0:, 1:), intent(in),    optional :: x_in
      real(dp),     dimension(0:, 1:), intent(inout), optional :: y_out

      integer(i4b), allocatable, dimension(:)         :: flag
      integer(i4b), allocatable, dimension(:, :)      :: pix, psi

      logical(lgt) :: finished
      integer(i4b) :: i, j, k, ntod, ndet, lpix, rpix, lpsi, rpsi, ierr
      integer(i4b) :: nhorn, t, sgn, pA, pB, f_A, f_B, nside, npix, nmaps
      real(dp)     :: inv_sigmasq, var, dA, dB, iA, iB, sA, sB, d, p, x_im, dx_im
      real(dp), allocatable, dimension(:,:) :: x, y
      nhorn = tod%nhorn
      ndet  = tod%ndet
      nside = tod%nside
      nmaps = tod%nmaps
      npix  = 12*nside**2

      allocate(x(0:npix-1,nmaps), y(0:npix-1,nmaps))
      if (tod%myid == 0) then
         finished = .false.
         call mpi_bcast(finished, 1,  MPI_LOGICAL, 0, tod%info%comm, ierr)
         x = x_in
      end if
      call mpi_bcast(x, size(x),  MPI_DOUBLE_PRECISION, 0, tod%info%comm, ierr)

      x_im   = 0.5*(x_imarr(1) + x_imarr(2))
      dx_im  = 0.5*(x_imarr(1) - x_imarr(2))
      y      = 0.d0
      do j = 1, tod%nscan
         ntod = tod%scans(j)%ntod
         allocate (pix(ntod, nhorn))             ! Decompressed pointing
         allocate (psi(ntod, nhorn))             ! Decompressed pol angle
         allocate (flag(ntod))                   ! Decompressed flags
         !do k = 1, tod%ndet
         if (tod%scans(j)%d(1)%accept) then
            call tod%decompress_pointing_and_flags(j, 1, pix, &
                & psi, flag)

            !inv_sigmasq = 0.d0 
            var = 0
            do k = 1, 4
               var = var + (tod%scans(j)%d(k)%sigma0/tod%scans(j)%d(k)%gain)**2/4
               !inv_sigmasq = inv_sigmasq  + (tod%scans(j)%d(k)%gain/tod%scans(j)%d(k)%sigma0)**2
            end do
            inv_sigmasq = 1.d0/var

            do t = 1, ntod

               if (flag(t) /= 0 .and. flag(t) /= 262144) cycle
               lpix = pix(t, 1)
               rpix = pix(t, 2)
               lpsi = psi(t, 1)
               rpsi = psi(t, 2)

               f_A = pmask(rpix)
               f_B = pmask(lpix)
               ! This is the model for each timestream
               ! The sgn parameter is +1 for timestreams 13 and 14, -1
               ! for timestreams 23 and 24, and also is used to switch
               ! the sign of the polarization sensitive parts of the
               ! model
               iA = x(lpix, 1)
               iB = x(rpix, 1)
               sA = x(lpix, 2)*tod%cos2psi(lpsi) + x(lpix, 3)*tod%sin2psi(lpsi)
               sB = x(rpix, 2)*tod%cos2psi(rpsi) + x(rpix, 3)*tod%sin2psi(rpsi)
               d  = (1.d0+x_im)*iA - (1.d0-x_im)*iB + dx_im*(sA + sB)
               p  = (1.d0+x_im)*sA - (1.d0-x_im)*sB + dx_im*(iA + iB)
               ! Temperature
               y(lpix, 1) = y(lpix, 1) + f_A*((1.d0 + x_im)*d + dx_im*p) * inv_sigmasq
               y(rpix, 1) = y(rpix, 1) - f_B*((1.d0 - x_im)*d - dx_im*p) * inv_sigmasq
               ! Q
               y(lpix, 2) = y(lpix, 2) + f_A*((1.d0 + x_im)*p + dx_im*d) * tod%cos2psi(lpsi)*inv_sigmasq
               y(rpix, 2) = y(rpix, 2) - f_B*((1.d0 - x_im)*p - dx_im*d) * tod%cos2psi(rpsi)*inv_sigmasq
               ! U
               y(lpix, 3) = y(lpix, 3) + f_A*((1.d0 + x_im)*p + dx_im*d) * tod%sin2psi(lpsi)*inv_sigmasq
               y(rpix, 3) = y(rpix, 3) - f_B*((1.d0 - x_im)*p - dx_im*d) * tod%sin2psi(rpsi)*inv_sigmasq
            end do
         end if
         deallocate (pix, psi, flag)
      end do

      if (tod%myid == 0) then
         call mpi_reduce(y, y_out, size(y), MPI_DOUBLE_PRECISION,MPI_SUM,&
              & 0, tod%info%comm, ierr)
      else
         call mpi_reduce(y, y,     size(y), MPI_DOUBLE_PRECISION,MPI_SUM,&
              & 0, tod%info%comm, ierr)
      end if

      deallocate(x, y)

   end subroutine compute_Ax

  subroutine finalize_binned_map(tod, binmap, handle, rms, scale, chisq_S, mask)
    implicit none
    class(comm_tod),                      intent(in)    :: tod
    type(comm_binmap),                    intent(inout) :: binmap
    type(planck_rng),                     intent(inout) :: handle
    class(comm_map),                      intent(inout) :: rms
    real(dp),                             intent(in)    :: scale
    real(dp),        dimension(1:,1:),    intent(out),   optional :: chisq_S
    real(sp),        dimension(0:),       intent(in),    optional :: mask

    integer(i4b) :: i, j, k, nmaps, ierr, ndet, ncol, n_A, off, ndelta
    integer(i4b) :: det, nout, np0, comm, myid, nprocs
    real(dp), allocatable, dimension(:,:)   :: A_inv, As_inv, buff_2d
    real(dp), allocatable, dimension(:,:,:) :: b_tot, bs_tot, buff_3d
    real(dp), allocatable, dimension(:)     :: W, eta
    real(dp), allocatable, dimension(:,:)   :: A_tot
    class(comm_mapinfo), pointer :: info 
    class(comm_map), pointer :: smap 

    myid  = tod%myid
    nprocs= tod%numprocs
    comm  = tod%comm
    np0   = tod%info%np
    nout  = size(binmap%sb_map%a,dim=1)
    nmaps = tod%info%nmaps
    ndet  = tod%ndet
    n_A   = size(binmap%sA_map%a,dim=1)
    ncol  = size(binmap%sb_map%a,dim=2)
    ndelta = 0; if (present(chisq_S)) ndelta = size(chisq_S,dim=2)

    ! Collect contributions from all nodes
    call mpi_win_fence(0, binmap%sA_map%win, ierr)
    if (binmap%sA_map%myid_shared == 0) then
       do i = 1, size(binmap%sA_map%a, 1)
          call mpi_allreduce(MPI_IN_PLACE, binmap%sA_map%a(i, :), size(binmap%sA_map%a, 2), &
               & MPI_DOUBLE_PRECISION, MPI_SUM, binmap%sA_map%comm_inter, ierr)
       end do
    end if
      call mpi_win_fence(0, binmap%sA_map%win, ierr)
      call mpi_win_fence(0, binmap%sb_map%win, ierr)
      if (binmap%sb_map%myid_shared == 0) then
         do i = 1, size(binmap%sb_map%a, 1)
            call mpi_allreduce(mpi_in_place, binmap%sb_map%a(i, :, :), size(binmap%sb_map%a(1, :, :)), &
                 & MPI_DOUBLE_PRECISION, MPI_SUM, binmap%sb_map%comm_inter, ierr)
         end do
      end if
      call mpi_win_fence(0, binmap%sb_map%win, ierr)

      allocate (A_tot(n_A, 0:np0 - 1), b_tot(nout, nmaps, 0:np0 - 1), bs_tot(nout, ncol, 0:np0 - 1), W(nmaps), eta(nmaps))
      A_tot = binmap%sA_map%a(:, tod%info%pix + 1)
      b_tot = binmap%sb_map%a(:, 1:nmaps, tod%info%pix + 1)
      bs_tot = binmap%sb_map%a(:, :, tod%info%pix + 1)

      ! Solve for local map and rms
      allocate (A_inv(nmaps, nmaps), As_inv(ncol, ncol))
      if (present(chisq_S)) chisq_S = 0.d0
      do i = 0, np0 - 1
         if (all(b_tot(1, :, i) == 0.d0)) then
            if (.not. present(chisq_S)) then
               rms%map(i, :) = 0.d0
               do k = 1, nout
                  binmap%outmaps(k)%p%map(i, :) = 0.d0
               end do
            end if
            cycle
         end if

         A_inv = 0.d0
         A_inv(1, 1) = A_tot(1, i)
         A_inv(2, 1) = A_tot(2, i)
         A_inv(1, 2) = A_inv(2, 1)
         A_inv(2, 2) = A_tot(3, i)
         A_inv(3, 1) = A_tot(4, i)
         A_inv(1, 3) = A_inv(3, 1)
         A_inv(3, 2) = A_tot(5, i)
         A_inv(2, 3) = A_inv(3, 2)
         A_inv(3, 3) = A_tot(6, i)
         if (present(chisq_S)) then
            As_inv = 0.d0
            As_inv(1:nmaps, 1:nmaps) = A_inv
            do det = 1, ndet - 1
               off = 6 + 4*(det - 1)
               As_inv(1, 3 + det) = A_tot(off + 1, i)
               As_inv(3 + det, 1) = As_inv(1, 3 + det)
               As_inv(2, 3 + det) = A_tot(off + 2, i)
               As_inv(3 + det, 2) = As_inv(2, 3 + det)
               As_inv(3, 3 + det) = A_tot(off + 3, i)
               As_inv(3 + det, 3) = As_inv(3, 3 + det)
               As_inv(3 + det, 3 + det) = A_tot(off + 4, i)
            end do
         end if

         call invert_singular_matrix(A_inv, 1d-12)
         do k = 1, tod%output_n_maps
            b_tot(k, 1:nmaps, i) = matmul(A_inv, b_tot(k, 1:nmaps, i))
         end do
         if (present(chisq_S)) then
            call invert_singular_matrix(As_inv, 1d-12)
            bs_tot(1, 1:ncol, i) = matmul(As_inv, bs_tot(1, 1:ncol, i))
            do k = tod%output_n_maps + 1, nout
               bs_tot(k, 1:ncol, i) = matmul(As_inv, bs_tot(k, 1:ncol, i))
            end do
         end if

         if (present(chisq_S)) then
            do j = 1, ndet - 1
               if (mask(tod%info%pix(i + 1)) == 0.) cycle
               if (As_inv(nmaps + j, nmaps + j) <= 0.d0) cycle
               chisq_S(j, 1) = chisq_S(j, 1) + bs_tot(1, nmaps + j, i)**2/As_inv(nmaps + j, nmaps + j)
               do k = 2, ndelta
                  chisq_S(j, k) = chisq_S(j, k) + bs_tot(tod%output_n_maps + k - 1, nmaps + j, i)**2/As_inv(nmaps + j, nmaps + j)
               end do
            end do
         end if
         do j = 1, nmaps
            rms%map(i, j) = sqrt(A_inv(j, j))*scale
            do k = 1, tod%output_n_maps
               binmap%outmaps(k)%p%map(i, j) = b_tot(k, j, i)*scale
            end do
         end do
      end do

      if (present(chisq_S)) then
         if (myid == 0) then
            call mpi_reduce(mpi_in_place, chisq_S, size(chisq_S), &
                 & MPI_DOUBLE_PRECISION, MPI_SUM, 0, comm, ierr)
         else
            call mpi_reduce(chisq_S, chisq_S, size(chisq_S), &
                 & MPI_DOUBLE_PRECISION, MPI_SUM, 0, comm, ierr)
         end if
      end if

      deallocate (A_inv, As_inv, A_tot, b_tot, bs_tot, W, eta)

   end subroutine finalize_binned_map


end module comm_tod_mapmaking_mod
