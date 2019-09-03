module comm_tod_LFI_mod
  use comm_tod_mod
  use comm_param_mod
  use comm_map_mod
  use comm_conviqt_mod
  use pix_tools
  use healpix_types  
  use comm_huffman_mod
  use comm_hdf_mod
  use comm_shared_arr_mod
  use spline_1D_mod
  implicit none

  private
  public comm_LFI_tod

  integer(i4b), parameter :: N_test      = 16
  integer(i4b), parameter :: samp_N      = 1
  integer(i4b), parameter :: prep_G      = 15
  integer(i4b), parameter :: samp_G      = 2
  integer(i4b), parameter :: prep_acal   = 3
  integer(i4b), parameter :: samp_acal   = 4
  integer(i4b), parameter :: prep_relbp  = 5
  integer(i4b), parameter :: prep_absbp  = 16
  integer(i4b), parameter :: samp_bp     = 11
  integer(i4b), parameter :: samp_sl     = 6
  integer(i4b), parameter :: samp_N_par  = 7
  integer(i4b), parameter :: sel_data    = 8
  integer(i4b), parameter :: bin_map     = 9
  integer(i4b), parameter :: calc_chisq  = 10
  integer(i4b), parameter :: output_slist = 12 
  integer(i4b), parameter :: samp_mono   = 13
  integer(i4b), parameter :: sub_sl      = 14
  logical(lgt), dimension(N_test) :: do_oper


  type, extends(comm_tod) :: comm_LFI_tod 
   contains
     procedure     :: process_tod        => process_LFI_tod
     procedure     :: compute_binned_map
     procedure     :: project_sky
     procedure     :: compute_orbital_dipole
     procedure     :: sample_gain
     procedure     :: sample_smooth_gain
     procedure     :: sample_n_corr
     procedure     :: sample_bp
     procedure     :: compute_cleaned_tod
     procedure     :: construct_sl_template
     procedure     :: compute_chisq
     procedure     :: sample_noise_psd
     procedure     :: decompress_pointing_and_flags
     procedure     :: accumulate_absgain_from_orbital
     procedure     :: sample_absgain_from_orbital
     procedure     :: sample_mono
     procedure     :: get_total_chisq
     procedure     :: output_scan_list
     procedure     :: finalize_binned_map
     procedure     :: symmetrize_flags
  end type comm_LFI_tod

  interface comm_LFI_tod
     procedure constructor
  end interface comm_LFI_tod

contains

  !**************************************************
  !             Constructor
  !**************************************************
  function constructor(cpar, id_abs, info)
    implicit none
    type(comm_params),       intent(in) :: cpar
    integer(i4b),            intent(in) :: id_abs
    class(comm_mapinfo),     target     :: info
    class(comm_LFI_tod),     pointer    :: constructor

    integer(i4b) :: i, j, k, l, m, nside_beam, lmax_beam, nmaps_beam, ndelta, np_vec, ierr
    character(len=512) :: datadir
    logical(lgt) :: pol_beam
    type(hdf_file) :: h5_file
    integer(i4b), allocatable, dimension(:) :: pix

    ! Set up LFI specific parameters
    allocate(constructor)
    constructor%myid          = cpar%myid_chain
    constructor%comm          = cpar%comm_chain
    constructor%numprocs      = cpar%numprocs
    constructor%myid_shared   = cpar%myid_shared
    constructor%comm_shared   = cpar%comm_shared
    constructor%myid_inter    = cpar%myid_inter
    constructor%comm_inter    = cpar%comm_inter
    constructor%info          => info
    constructor%output_n_maps = 4
    constructor%init_from_HDF = cpar%ds_tod_initHDF(id_abs)
    constructor%freq          = cpar%ds_label(id_abs)
    constructor%operation     = cpar%operation
    constructor%outdir        = cpar%outdir
    constructor%first_call    = .true.
    call mpi_comm_size(cpar%comm_shared, constructor%numprocs_shared, ierr)

    datadir = trim(cpar%datadir)//'/' 
    constructor%filelist    = trim(datadir)//trim(cpar%ds_tod_filelist(id_abs))
    constructor%procmaskf1  = trim(datadir)//trim(cpar%ds_tod_procmask1(id_abs))
    constructor%procmaskf2  = trim(datadir)//trim(cpar%ds_tod_procmask2(id_abs))
    constructor%instfile    = trim(datadir)//trim(cpar%ds_tod_instfile(id_abs))

    call constructor%get_scan_ids(constructor%filelist)

    constructor%procmask => comm_map(constructor%info, constructor%procmaskf1)
    constructor%procmask2 => comm_map(constructor%info, constructor%procmaskf2)
    do i = 0, constructor%info%np-1
       if (any(constructor%procmask%map(i,:) < 0.5d0)) then
          constructor%procmask%map(i,:) = 0.d0
       else
          constructor%procmask%map(i,:) = 1.d0
       end if
       if (any(constructor%procmask2%map(i,:) < 0.5d0)) then
          constructor%procmask2%map(i,:) = 0.d0
       else
          constructor%procmask2%map(i,:) = 1.d0
       end if
    end do


    constructor%nmaps    = info%nmaps
    constructor%ndet     = num_tokens(cpar%ds_tod_dets(id_abs), ",")
    constructor%nhorn    = 1
    allocate(constructor%stokes(constructor%nmaps))
    allocate(constructor%w(constructor%nmaps,constructor%nhorn,constructor%ndet))
    allocate(constructor%label(constructor%ndet))
    allocate(constructor%partner(constructor%ndet))
    constructor%stokes = [1,2,3]
    constructor%w      = 1.d0
    call get_tokens(cpar%ds_tod_dets(id_abs), ",", constructor%label)
    do i = 1, constructor%ndet
       if (mod(i,2) == 1) then
          constructor%partner(i) = i+1
       else
          constructor%partner(i) = i-1
       end if
    end do


    if (trim(cpar%ds_bpmodel(id_abs)) == 'additive_shift') then
       ndelta = 1
    else if (trim(cpar%ds_bpmodel(id_abs)) == 'powlaw_tilt') then
       ndelta = 1
    else
       write(*,*) 'Unknown bandpass model'
       stop
    end if
    allocate(constructor%bp_delta(0:constructor%ndet,ndelta))
    allocate(constructor%sigma_bp(0:constructor%ndet,ndelta))

    ! Read the actual TOD
    call constructor%read_tod(constructor%label)

    ! Initialize beams
    allocate(constructor%fwhm(constructor%ndet))
    allocate(constructor%elip(constructor%ndet))
    allocate(constructor%psi_ell(constructor%ndet))
    
    call open_hdf_file(constructor%instfile, h5_file, 'r')
    nside_beam = 128
    nmaps_beam = 3
    pol_beam   = .true.
    call read_hdf(h5_file, trim(adjustl(constructor%label(1)))//'/'//'sllmax', lmax_beam)
    constructor%slinfo => comm_mapinfo(cpar%comm_chain, nside_beam, lmax_beam, &
         & nmaps_beam, pol_beam)
    allocate(constructor%slbeam(constructor%ndet), constructor%slconv(constructor%ndet))
    do i = 1, constructor%ndet
       constructor%slbeam(i)%p => comm_map(constructor%slinfo, h5_file, .true., .true., &
            & trim(constructor%label(i)))

!!$          call constructor%slbeam(i)%p%Y
!!$          call constructor%slbeam(i)%p%writeFITS("beam.fits")
!!$          call mpi_finalize(m)
!!$          stop
          

!!$          do j = 0, constructor%slbeam(i)%p%info%nalm-1
!!$             l = constructor%slbeam(i)%p%info%lm(1,j)
!!$             m = constructor%slbeam(i)%p%info%lm(2,j)
!!$             if (m == 0) then
!!$                constructor%slbeam(i)%p%alm(j,1) = exp(-0.5d0*l*(l+1)*(420.d0*pi/180.d0/60.d0/sqrt(8.d0*log(2.d0)))**2)
!!$             else
!!$                constructor%slbeam(i)%p%alm(j,1) = 0.d0
!!$             end if
!!$          end do
    end do
    
    do i = 1, constructor%ndet
       call read_hdf(h5_file, trim(adjustl(constructor%label(i)))//'/'//'fwhm', constructor%fwhm(i))
       call read_hdf(h5_file, trim(adjustl(constructor%label(i)))//'/'//'elip', constructor%elip(i))
       call read_hdf(h5_file, trim(adjustl(constructor%label(i)))//'/'//'psi_ell', constructor%psi_ell(i))
    end do
    call close_hdf_file(h5_file)
 
    ! Lastly, create a vector pointing table for fast look-up for orbital dipole
    np_vec = 12*constructor%nside**2 !npix
    allocate(constructor%pix2vec(3,0:np_vec-1))
    do i = 0, np_vec-1
       call pix2vec_ring(constructor%nside, i, constructor%pix2vec(:,i))
    end do

    ! Construct observed pixel array
    allocate(constructor%pix2ind(0:12*constructor%nside**2-1))
    constructor%pix2ind = -1
    do i = 1, constructor%nscan
       allocate(pix(constructor%scans(i)%ntod))          
       do j = 1, constructor%ndet
          call huffman_decode(constructor%scans(i)%hkey, &
               constructor%scans(i)%d(j)%pix, pix)
          constructor%pix2ind(pix(1)) = 1
          do k = 2, constructor%scans(i)%ntod
             pix(k)  = pix(k-1)  + pix(k)
             constructor%pix2ind(pix(k)) = 1
          end do
       end do
       deallocate(pix)
    end do
    constructor%nobs = count(constructor%pix2ind == 1) 
    allocate(constructor%ind2pix(constructor%nobs))
    j = 1
    do i = 0, 12*constructor%nside**2-1
       if (constructor%pix2ind(i) == 1) then
          constructor%ind2pix(j) = i 
          constructor%pix2ind(i) = j
          j = j+1
       end if
    end do
    if (constructor%myid == 0) then
       write(*,*) '  TOD-map filling factor = ', &
            & constructor%nobs/(12.*constructor%nside**2)
    end if

!!$    do i = 1, constructor%nobs
!!$       write(*,*) i, constructor%ind2pix(i)
!!$    end do
!!$    call mpi_finalize(i)
!!$    stop

  end function constructor

  !**************************************************
  !             Driver routine
  !**************************************************
  subroutine process_LFI_tod(self, chaindir, chain, iter, handle, map_in, delta, map_out, rms_out)
    implicit none
    class(comm_LFI_tod),                      intent(inout) :: self
    character(len=*),                         intent(in)    :: chaindir
    integer(i4b),                             intent(in)    :: chain, iter
    type(planck_rng),                         intent(inout) :: handle
    type(map_ptr),       dimension(1:,1:),    intent(inout) :: map_in       ! (ndet,ndelta)
    real(dp),            dimension(0:,1:,1:), intent(inout) :: delta        ! (0:ndet,npar,ndelta) BP corrections
    class(comm_map),                          intent(inout) :: map_out      ! Combined output map
    class(comm_map),                          intent(inout) :: rms_out      ! Combined output rms

    integer(i4b) :: i, j, k, l, start_chunk, end_chunk, chunk_size, ntod, ndet
    integer(i4b) :: nside, npix, nmaps, naccept, ntot, ns
    integer(i4b) :: ierr, main_iter, n_main_iter, ndelta, scanfile, ncol, n_A, nout
    real(dp)     :: t1, t2, t3, t4, t5, t6, t7, t8, chisq_threshold, delta_temp, chisq_tot
    real(dp)     :: t_tot(22), inv_gain
    real(sp),     allocatable, dimension(:,:)     :: n_corr, s_sl, s_sky, s_orb, mask,mask2, s_bp
    real(sp),     allocatable, dimension(:,:)     :: s_sky_prop, s_bp_prop, s_mono, s_buf, s_tot
    real(sp),     allocatable, dimension(:,:,:)   :: d_calib
    real(dp),     allocatable, dimension(:,:,:,:) :: map_sky
    real(dp),     allocatable, dimension(:)       :: A_abscal, b_abscal
    real(dp),     allocatable, dimension(:,:)     :: chisq_S
    real(dp),     allocatable, dimension(:,:)     :: A_map
    integer(i4b), allocatable, dimension(:,:)     :: nhit
    real(dp),     allocatable, dimension(:,:,:)   :: b_map, b_mono, sys_mono
    integer(i4b), allocatable, dimension(:,:)     :: pix, psi, flag, pind
    logical(lgt)       :: correct_sl
    character(len=512) :: prefix, postfix, Sfilename
    character(len=4)   :: ctext
    character(len=6)   :: samptext
    character(len=512), allocatable, dimension(:) :: slist
    character(len=8)   :: id, stext
    character(len=1)   :: did
    character(len=5)   :: istr
    type(shared_1d_int) :: sprocmask, sprocmask2
    type(shared_2d_sp), allocatable, dimension(:,:) :: smap_sky
    type(shared_2d_dp) :: sA_map
    type(shared_3d_dp) :: sb_map, sb_mono
    class(comm_map), pointer :: map_sl, map_sl2, condmap
    class(map_ptr), allocatable, dimension(:) :: outmaps
    class(comm_mapinfo), pointer :: info_sl2, info_sl_map

    call int2string(iter, ctext)
    call update_status(status, "tod_start"//ctext)

    t_tot   = 0.d0
    call wall_time(t5)

    if (self%myid == 0) then
       write(*,*) 'delta in 1=', real(delta(:,1,1),sp)
       write(*,*) 'delta in 2=', real(delta(:,1,2),sp)
    end if

    ! Set up full-sky map structures
    call wall_time(t1)
    correct_sl      = .false.
    chisq_threshold = 10.d0 !7.d0
    n_main_iter     = 4
    !chisq_threshold = 20000.d0 
    !this ^ should be 7.d0, is currently 2000 to debug sidelobes
    ndet            = self%ndet
    ndelta          = size(delta,3)
    nside           = map_out%info%nside
    nmaps           = map_out%info%nmaps
    npix            = 12*nside**2
    chunk_size      = npix/self%numprocs_shared
    if (chunk_size*self%numprocs_shared /= npix) chunk_size = chunk_size+1
    allocate(A_abscal(self%ndet), b_abscal(self%ndet))
    allocate(smap_sky(0:ndet, ndelta)) 
    allocate(chisq_S(ndet,2))
    allocate(slist(self%nscan))
    slist   = ''

    call int2string(chain, ctext)
    call int2string(iter, samptext)
    prefix = trim(chaindir) // '/tod_' // trim(self%freq) // '_'
    postfix = '_c' // ctext // '_k' // samptext // '.fits'

!!$    call int2string(iter, istr)
!!$    do j = 1, map_in(1,1)%p%info%nmaps
!!$       do i = 0, map_in(1,1)%p%info%np-1
!!$          map_in(1,1)%p%map(i,j) = sum(map_in(:,1)%p%map(i,j))/4 
!!$       end do
!!$    end do
!!$    call map_in(1,1)%p%writeFITS("refmap"//istr//".fits")
!!$    call mpi_finalize(ierr)
!!$    stop

    ! Distribute fullsky maps
    do j = 1, ndelta
       do i = 1, self%ndet
          map_in(i,j)%p%map = 1d-6 * map_in(i,j)%p%map ! uK to K
          call init_shared_2d_sp(self%myid_shared, self%comm_shared, &
               & self%myid_inter, self%comm_inter, [nmaps,npix], smap_sky(i,j))
          call sync_shared_2d_sp_map(smap_sky(i,j), map_in(i,j)%p%info%pix, &
               & transpose(map_in(i,j)%p%map))
          call mpi_win_fence(0, smap_sky(i,j)%win, ierr)
       end do
       call init_shared_2d_sp(self%myid_shared, self%comm_shared, &
            & self%myid_inter, self%comm_inter, [nmaps,npix], smap_sky(0,j))
       if (self%myid_shared == 0) then
          smap_sky(0,j)%a = smap_sky(1,j)%a
          do i = 2, self%ndet
             smap_sky(0,j)%a = smap_sky(0,j)%a + smap_sky(i,j)%a 
          end do
          smap_sky(0,j)%a = smap_sky(0,j)%a/self%ndet
       end if
       call mpi_win_fence(0, smap_sky(0,j)%win, ierr)
    end do

    ! Set up shared processing mask
    call init_shared_1d_int(self%myid_shared, self%comm_shared, &
         & self%myid_inter, self%comm_inter, [npix], sprocmask)
    call sync_shared_1d_int_map(sprocmask, self%procmask%info%pix, &
         & nint(self%procmask%map(:,1)))
    call init_shared_1d_int(self%myid_shared, self%comm_shared, &
         & self%myid_inter, self%comm_inter, [npix], sprocmask2)
    call sync_shared_1d_int_map(sprocmask2, self%procmask2%info%pix, &
         & nint(self%procmask2%map(:,1)))
    call wall_time(t2); t_tot(9) = t2-t1


    ! Compute far sidelobe Conviqt structures
    call wall_time(t1)
!!$map_in(1,1)%p%map = 0
!!$if (self%myid == 32) map_in(1,1)%p%map(5200,1) = 1
!!$call map_in(1,1)%p%writeFITS("in.fits")
    if (self%myid == 0) write(*,*) 'Precomputing sidelobe convolved sky'
    do i = 1, self%ndet
       if (.not. correct_sl) exit

       !call map_in(i,1)%p%remove_MDpoles() !remove mono and dipole components
       !call map_in(i,1)%p%writeFITS('nodp.fits')
       call map_in(i,1)%p%YtW()  ! Compute sky a_lms
       self%slconv(i)%p => comm_conviqt(self%myid_shared, self%comm_shared, &
            & self%myid_inter, self%comm_inter, 128, 256, 3, 256, &
            & self%slbeam(i)%p, map_in(i,1)%p, 2)
    end do
    call wall_time(t2); t_tot(13) = t2-t1

    call update_status(status, "tod_init")

    ! Compute output map and rms
    call wall_time(t3)
    do_oper             = .true.
    do main_iter = 1, n_main_iter

       call wall_time(t7)

       if (self%myid == 0) write(*,*) '  Performing main iteration = ', main_iter
          
       ! Select operations for current iteration
       do_oper(bin_map)      = (main_iter == n_main_iter  )
       do_oper(sel_data)     = (main_iter == n_main_iter  ) .and.       self%first_call
       do_oper(calc_chisq)   = (main_iter == n_main_iter  ) 
       do_oper(prep_acal)    = (main_iter == n_main_iter-1) .and. .not. self%first_call
       do_oper(samp_acal)    = (main_iter == n_main_iter  ) .and. .not. self%first_call
       do_oper(prep_relbp)   = (main_iter == n_main_iter-2) .and. .not. self%first_call !.and. mod(iter,2) == 0
       do_oper(prep_absbp)   = .false. !(main_iter == n_main_iter-2) .and. .not. self%first_call !.and. mod(iter,2) == 1
       do_oper(samp_bp)      = (main_iter == n_main_iter-1) .and. .not. self%first_call
       do_oper(prep_G)       = (main_iter == n_main_iter-3) .and. .not. self%first_call
       do_oper(samp_G)       = (main_iter == n_main_iter-2) .and. .not. self%first_call
       do_oper(samp_N)       = .true.
       do_oper(samp_mono)    = do_oper(bin_map)             .and. .not. self%first_call
       do_oper(sub_sl)       = correct_sl
       do_oper(output_slist) = mod(iter, 10) == 0

       ! Perform pre-loop operations
       if (do_oper(bin_map) .or. do_oper(prep_relbp)) then
          if (do_oper(bin_map)) then
             ncol = nmaps
             n_A  = nmaps*(nmaps+1)/2
             nout = self%output_n_maps
             allocate(outmaps(nout))
             do i = 1, nout
                outmaps(i)%p => comm_map(map_out%info)
             end do
          else
             ncol = nmaps + ndet - 1
             n_A  = nmaps*(nmaps+1)/2 + 4*(ndet-1)
             nout = 2
          end if
          if (allocated(A_map)) deallocate(A_map, b_map)
          allocate(A_map(n_A,self%nobs), b_map(nout,ncol,self%nobs))
          A_map = 0.d0; b_map = 0.d0         
          if (sA_map%init) call dealloc_shared_2d_dp(sA_map)
          call init_shared_2d_dp(self%myid_shared, self%comm_shared, &
               & self%myid_inter, self%comm_inter, [n_A,npix], sA_map)
          call mpi_win_fence(0, sA_map%win, ierr)
          if (sA_map%myid_shared == 0) sA_map%a = 0.d0
          call mpi_win_fence(0, sA_map%win, ierr)
          if (sb_map%init) call dealloc_shared_3d_dp(sb_map)
          call init_shared_3d_dp(self%myid_shared, self%comm_shared, &
               & self%myid_inter, self%comm_inter, [nout,ncol,npix], sb_map)
          call mpi_win_fence(0, sb_map%win, ierr)
          if (sb_map%myid_shared == 0) sb_map%a = 0.d0
          call mpi_win_fence(0, sb_map%win, ierr)
       end if

       if (do_oper(samp_mono)) then
          allocate(b_mono(nmaps,self%nobs,ndet), sys_mono(nmaps,nmaps+ndet,0:self%info%np-1))
          b_mono = 0.d0
          call init_shared_3d_dp(self%myid_shared, self%comm_shared, &
               & self%myid_inter, self%comm_inter, [nmaps,npix,ndet], sb_mono)
          call mpi_win_fence(0, sb_mono%win, ierr)
          if (sb_map%myid_shared == 0) sb_mono%a = 0.d0
          call mpi_win_fence(0, sb_mono%win, ierr)
       end if

       if (do_oper(sel_data)) then
          naccept = 0; ntot    = 0
       end if

       if (do_oper(prep_acal)) then
          A_abscal = 0.d0; b_abscal = 0.d0
       end if

       if (do_oper(samp_acal)) then
          call wall_time(t1)
          call self%sample_absgain_from_orbital(A_abscal, b_abscal)
          call wall_time(t2); t_tot(16) = t_tot(16) + t2-t1
       end if

       if (do_oper(samp_bp)) then
          call wall_time(t1)
          call self%sample_bp(iter, delta, smap_sky, handle, chisq_S)
          call wall_time(t2); t_tot(17) = t_tot(17) + t2-t1
       end if

       if (do_oper(samp_G)) then
          call wall_time(t1)
          call self%sample_smooth_gain()
          call wall_time(t2); t_tot(4) = t_tot(4) + t2-t1
       end if

       if (do_oper(prep_absbp)) then
          chisq_S = 0.d0
       end if

       call wall_time(t8); t_tot(19) = t_tot(19) + t8-t7

       ! Perform main analysis loop
       do i = 1, self%nscan

          !call update_status(status, "tod_loop1")
          call wall_time(t7)

          if (.not. any(self%scans(i)%d%accept)) cycle

          ! Short-cuts to local variables
          call wall_time(t1)
          ntod = self%scans(i)%ntod
          ndet = self%ndet
          
          ! Set up local data structure for current scan
          allocate(n_corr(ntod, ndet))       ! Correlated noise in V
          allocate(s_sl(ntod, ndet))         ! Sidelobe in uKcm
          allocate(s_sky(ntod, ndet))        ! Sky signal in uKcmb
          allocate(s_sky_prop(ntod, ndet))   ! Sky signal in uKcmb
          allocate(s_bp(ntod, ndet))         ! Signal minus mean
          allocate(s_bp_prop(ntod, ndet))    ! Signal minus mean
          allocate(s_orb(ntod, ndet))        ! Orbital dipole in uKcmb
          allocate(s_mono(ntod, ndet))       ! Monopole correction in uKcmb
          allocate(s_buf(ntod, ndet))       ! Buffer
          allocate(s_tot(ntod, ndet))       ! Sum of all sky compnents
          allocate(mask(ntod, ndet))         ! Processing mask in time
          allocate(mask2(ntod, ndet))        ! Processing mask in time
          allocate(pix(ntod, ndet))          ! Decompressed pointing
          allocate(psi(ntod, ndet))          ! Decompressed pol angle
          allocate(flag(ntod, ndet))         ! Decompressed flags
          
          ! Initializing arrays to zero
          !n_corr      = 0.d0
          !s_sl        = 0.d0
          !s_sky       = 0.d0
          !s_sky_prop  = 0.d0
          !s_orb       = 0.d0
          !s_mono      = 0.d0
          call wall_time(t2); t_tot(18) = t_tot(18) + t2-t1
          
          ! --------------------
          ! Analyze current scan
          ! --------------------
         
          ! Decompress pointing, psi and flags for current scan
          call wall_time(t1)
          do j = 1, ndet
             if (.not. self%scans(i)%d(j)%accept) cycle
             call self%decompress_pointing_and_flags(i, j, pix(:,j), &
                  & psi(:,j), flag(:,j))
          end do
          call self%symmetrize_flags(flag)
          !call validate_psi(self%scanid(i), psi)
          call wall_time(t2); t_tot(11) = t_tot(11) + t2-t1
          !call update_status(status, "tod_decomp")
          
          ! Construct sky signal template
          call wall_time(t1)
          if (do_oper(bin_map) .or. do_oper(prep_relbp)) then 
             call self%project_sky(smap_sky(:,1), pix, psi, flag, &
                  & sprocmask%a, i, s_sky, mask, s_bp=s_bp)  
          else 
             call self%project_sky(smap_sky(:,1), pix, psi, flag, &
                  & sprocmask%a, i, s_sky, mask)
          end if
          if (do_oper(prep_relbp)) then
             call self%project_sky(smap_sky(:,2), pix, psi, flag, &
                  & sprocmask2%a, i, s_sky_prop, mask2, s_bp=s_bp_prop)  
          else if (do_oper(prep_absbp)) then
             call self%project_sky(smap_sky(:,2), pix, psi, flag, &
                  & sprocmask2%a, i, s_sky_prop, mask2)  
          end if
          if (do_oper(sel_data)) then
             do j = 1, ndet
                if (all(mask(:,j) == 0)) self%scans(i)%d(j)%accept = .false.
             end do
          end if
          call wall_time(t2); t_tot(1) = t_tot(1) + t2-t1
          !call update_status(status, "tod_project")
          
          ! Construct orbital dipole template
          call wall_time(t1)
          call self%compute_orbital_dipole(i, pix, s_orb)
          call wall_time(t2); t_tot(2) = t_tot(2) + t2-t1
          !call update_status(status, "tod_orb")
           
          ! Construct sidelobe template 
          call wall_time(t1)
          if (do_oper(sub_sl)) then
             do j = 1, ndet
                if (.not. self%scans(i)%d(j)%accept) cycle
                call self%construct_sl_template(self%slconv(j)%p, i, &
                     & nside, pix(:,j), psi(:,j), s_sl(:,j), &
                     & self%mbang(j)+self%polang(j))
             end do
          else
             do j = 1, ndet
                if (.not. self%scans(i)%d(j)%accept) cycle
                s_sl(:,j) = 0.
             end do
          end if
          call wall_time(t2); t_tot(12) = t_tot(12) + t2-t1

          ! Construct monopole correction template 
          call wall_time(t1)
          do j = 1, ndet
             if (.not. self%scans(i)%d(j)%accept) cycle
             s_mono(:,j) = self%mono(j)
          end do
          s_tot = s_sky + s_sl + s_orb + s_mono
          call wall_time(t2); t_tot(1) = t_tot(1) + t2-t1

          ! Fit correlated noise
          if (do_oper(samp_N)) then
             call wall_time(t1)
             call self%sample_n_corr(handle, i, mask, s_tot, n_corr)
             call wall_time(t2); t_tot(3) = t_tot(3) + t2-t1
          else
             n_corr = 0.
          end if
             
          ! Compute noise spectrum
          if (do_oper(samp_N_par)) then
             call wall_time(t1)
             ! do j = 1, ndet
             !    if (.not. self%scans(i)%d(j)%accept) cycle
             call self%sample_noise_psd(handle, i, mask, s_tot, n_corr)
             ! end do
             call wall_time(t2); t_tot(6) = t_tot(6) + t2-t1
          end if

          ! Fit gain 
          if (do_oper(prep_G)) then
             call wall_time(t1)
             do j = 1, ndet
                if (.not. self%scans(i)%d(j)%accept) cycle
                call self%sample_gain(handle, j, i, n_corr(:, j), mask(:,j), &
                     & s_tot(:, j))
             end do
             call wall_time(t2); t_tot(4) = t_tot(4) + t2-t1
          end if

          ! Compute chisquare
          if (do_oper(calc_chisq)) then
             call wall_time(t1)
             do j = 1, ndet
                if (.not. self%scans(i)%d(j)%accept) cycle
                s_buf(:,j) =  s_sl(:,j) + s_orb(:,j) + s_mono(:,j)
                call self%compute_chisq(i, j, mask(:,j), s_sky(:,j), &
                     & s_buf(:,j), n_corr(:,j))
             end do
             call wall_time(t2); t_tot(7) = t_tot(7) + t2-t1
          end if

          ! Select data
          if (do_oper(sel_data)) then
             call wall_time(t1)
             do j = 1, ndet
                ntot= ntot + 1
                if (.not. self%scans(i)%d(j)%accept) cycle
                if (count(iand(flag(:,j),6111248) .ne. 0) > 0.1*ntod) then
                   !write(*,fmt='(a,i8,i5,a,f12.1)') 'Reject scan, det = ', &
                    !    & self%scanid(i), j, ', more than 10% flagged samples'
                   self%scans(i)%d(j)%accept = .false.
                else if (abs(self%scans(i)%d(j)%chisq) > chisq_threshold .or. &
                & isNaN(self%scans(i)%d(j)%chisq)) then
                   write(*,fmt='(a,i8,i5,a,f12.1)') 'Reject scan, det = ', &
                        & self%scanid(i), j, ', chisq = ', &
                        & self%scans(i)%d(j)%chisq
                   self%scans(i)%d(j)%accept = .false.
                   cycle
                else
                   naccept = naccept + 1
                end if
             end do
             do j = 1, ndet
                if (.not. self%scans(i)%d(j)%accept) then
                   self%scans(i)%d(self%partner(j))%accept = .false.
                end if
             end do
             call wall_time(t2); t_tot(15) = t_tot(15) + t2-t1
          end if

          ! Compute chisquare for bandpass fit
          if (do_oper(prep_absbp)) then
             call wall_time(t1)
             do j = 1, ndet
                if (.not. self%scans(i)%d(j)%accept) cycle
                s_buf(:,j) =  s_sl(:,j) + s_orb(:,j) + s_mono(:,j)
                call self%compute_chisq(i, j, mask2(:,j), s_sky(:,j), &
                     & s_buf(:,j), n_corr(:,j),  s_sky_prop(:,j))
                chisq_S(j,1) = chisq_S(j,1) + self%scans(i)%d(j)%chisq_masked
                chisq_S(j,2) = chisq_S(j,2) + self%scans(i)%d(j)%chisq_prop
             end do
             call wall_time(t2); t_tot(7) = t_tot(7) + t2-t1
          end if

          ! Prepare for absolute calibration
          if (do_oper(prep_acal)) then
             call wall_time(t1)
             do j = 1, ndet
                if (.not. self%scans(i)%d(j)%accept) cycle
                s_buf(:,j) =  s_tot(:,j) - s_orb(:,j) !s_sky(:,j) + s_sl(:,j) + s_mono(:,j)
                call self%accumulate_absgain_from_orbital(i, j, mask(:,j),&
                     & s_buf(:,j), s_orb(:,j), n_corr(:,j), &
                     & A_abscal(j), b_abscal(j))
             end do
             call wall_time(t2); t_tot(14) = t_tot(14) + t2-t1
          end if

          ! Compute binned map 
          if (do_oper(bin_map) .or. do_oper(prep_relbp)) then
             call wall_time(t1)
             allocate(d_calib(nout,ntod, ndet)) 
             do j = 1, ndet
                inv_gain       = 1.d0 / self%scans(i)%d(j)%gain
                d_calib(1,:,j) = (self%scans(i)%d(j)%tod - n_corr(:,j)) * &
                     & inv_gain - s_tot(:,j) + s_sky(:,j) - s_bp(:,j)
                if (do_oper(bin_map) .and. nout > 1) d_calib(2,:,j) = d_calib(1,:,j) - s_sky(:,j) + s_bp(:,j) ! Residual
                if (do_oper(bin_map) .and. nout > 2) d_calib(3,:,j) = n_corr(:,j) * inv_gain
                if (do_oper(bin_map) .and. nout > 3) d_calib(4,:,j) = s_bp(:,j)
                if (do_oper(bin_map) .and. nout > 4) d_calib(5,:,j) = s_mono(:,j)
                if (do_oper(bin_map) .and. nout > 5) d_calib(6,:,j) = s_orb(:,j)
                if (do_oper(bin_map) .and. nout > 6) d_calib(7,:,j) = s_sl(:,j)
                if (do_oper(prep_relbp)) then
                   d_calib(2,:,j) = d_calib(1,:,j) + s_bp(:,j) - s_bp_prop(:,j)
                end if
             end do
             call wall_time(t2); t_tot(5) = t_tot(5) + t2-t1

             call wall_time(t1)
             if (do_oper(samp_mono)) then
                call self%compute_binned_map(d_calib, pix, &
                     & psi, flag, A_map, b_map, i, do_oper(prep_relbp), b_mono=b_mono)
             else
                call self%compute_binned_map(d_calib, pix, &
                     & psi, flag, A_map, b_map, i, do_oper(prep_relbp))
             end if
             deallocate(d_calib)
             call wall_time(t2); t_tot(8) = t_tot(8) + t2-t1
          end if

          ! Clean up
          call wall_time(t1)
          deallocate(n_corr, s_sl, s_sky, s_orb, s_tot)
          deallocate(mask, mask2, pix, psi, flag, s_bp, s_sky_prop, s_bp_prop, s_buf, s_mono)
          call wall_time(t2); t_tot(18) = t_tot(18) + t2-t1

          call wall_time(t8); t_tot(19) = t_tot(19) + t8-t7

          if (do_oper(output_slist)) then
             self%scans(i)%proctime   = self%scans(i)%proctime   + t8-t7
             self%scans(i)%n_proctime = self%scans(i)%n_proctime + 1
             if (main_iter == n_main_iter) then
                write(slist(i),*) self%scanid(i), '"',trim(self%hdfname(i)), &
                     & '"', real(self%scans(i)%proctime/self%scans(i)%n_proctime,sp)
             end if
          end if
          !call update_status(status, "tod_loop2")

       end do

       ! Output total chisquare
       call wall_time(t7)
 
       if (do_oper(prep_relbp)) then
          call wall_time(t1)
          do i = 0, self%numprocs_shared-1
             start_chunk = mod(self%myid_shared+i,self%numprocs_shared)*chunk_size
             end_chunk   = min(start_chunk+chunk_size-1,npix-1)
             do while (start_chunk < npix)
                if (self%pix2ind(start_chunk) /= -1) exit
                start_chunk = start_chunk+1
             end do
             do while (end_chunk >= start_chunk)
                if (self%pix2ind(end_chunk) /= -1) exit
                end_chunk = end_chunk-1
             end do
             if (start_chunk < npix)       start_chunk = self%pix2ind(start_chunk)
             if (end_chunk >= start_chunk) end_chunk   = self%pix2ind(end_chunk)

             call mpi_win_fence(0, sA_map%win, ierr)
             call mpi_win_fence(0, sb_map%win, ierr)
             do j = start_chunk, end_chunk
                sA_map%a(:,self%ind2pix(j)+1) = sA_map%a(:,self%ind2pix(j)+1) + &
                     & A_map(:,j)
                sb_map%a(:,:,self%ind2pix(j)+1) = sb_map%a(:,:,self%ind2pix(j)+1) + &
                     & b_map(:,:,j)
             end do
          end do
          call mpi_win_fence(0, sA_map%win, ierr)
          call mpi_win_fence(0, sb_map%win, ierr)

          Sfilename = trim(prefix) // 'Smap'// trim(postfix) 
          call self%finalize_binned_map(handle, sA_map, sb_map, outmaps, &
               & rms_out, chisq_S, Sfile=Sfilename, mask=sprocmask2%a)
          call wall_time(t2); t_tot(10) = t_tot(10) + t2-t1
       end if
       call update_status(status, "tod_prepbp")

    end do
    call wall_time(t4)

    ! Output latest scan list with new timing information
    if (do_oper(output_slist)) then
       call update_status(status, "scanlist1")
       call wall_time(t1)
       call self%output_scan_list(slist)
       call wall_time(t2); t_tot(20) = t_tot(20) + t2-t1
       call update_status(status, "scanlist2")
    end if

    ! Solve combined map, summed over all pixels 
    call wall_time(t1)
    call update_status(status, "shared1")
    if (sA_map%init) then
       do i = 0, self%numprocs_shared-1
          start_chunk = mod(self%myid_shared+i,self%numprocs_shared)*chunk_size
          end_chunk   = min(start_chunk+chunk_size-1,npix-1)
          do while (start_chunk < npix)
             if (self%pix2ind(start_chunk) /= -1) exit
             start_chunk = start_chunk+1
          end do
          do while (end_chunk >= start_chunk)
             if (self%pix2ind(end_chunk) /= -1) exit
             end_chunk = end_chunk-1
          end do
          if (start_chunk < npix)       start_chunk = self%pix2ind(start_chunk)
          if (end_chunk >= start_chunk) end_chunk   = self%pix2ind(end_chunk)
          
          call mpi_win_fence(0, sA_map%win, ierr)
          call mpi_win_fence(0, sb_map%win, ierr)
          do j = start_chunk, end_chunk
             sA_map%a(:,self%ind2pix(j)+1) = sA_map%a(:,self%ind2pix(j)+1) + &
                  & A_map(:,j)
             sb_map%a(:,:,self%ind2pix(j)+1) = sb_map%a(:,:,self%ind2pix(j)+1) + &
                  & b_map(:,:,j)
          end do
          if (do_oper(samp_mono)) then
             call mpi_win_fence(0, sb_mono%win, ierr)
             do j = start_chunk, end_chunk
                sb_mono%a(:,self%ind2pix(j)+1,:) = sb_mono%a(:,self%ind2pix(j)+1,:) + &
                     & b_mono(:,j,:)
             end do
          end if
       end do
       call mpi_win_fence(0, sA_map%win, ierr)
       call mpi_win_fence(0, sb_map%win, ierr)
       if (do_oper(samp_mono)) call mpi_win_fence(0, sb_mono%win, ierr)

       call update_status(status, "shared2")

       call update_status(status, "finalize1")
       if (do_oper(samp_mono)) then
          call self%finalize_binned_map(handle, sA_map, sb_map, outmaps, rms_out, sb_mono=sb_mono, sys_mono=sys_mono)
!!$       condmap => comm_map(self%info)
!!$       call self%finalize_binned_map(handle, sA_map, sb_map, outmaps, rms_out, sb_mono=sb_mono, sys_mono=sys_mono, condmap=condmap)
!!$       call condmap%writeFITS("cond.fits")
!!$       call condmap%dealloc()
       else
          call self%finalize_binned_map(handle, sA_map, sb_map, outmaps, rms_out)
       end if

       call update_status(status, "finalize2")
       map_out%map = outmaps(1)%p%map
       
       ! Sample monopole coefficients
       if (do_oper(samp_mono)) then
          call self%sample_mono(handle, sys_mono, outmaps(2)%p, rms_out, &
               & self%procmask)
       end if

       ! Update bandpass parameters
       self%bp_delta = delta(:,:,1)

       ! Output maps to disk
       call map_out%writeFITS(trim(prefix)//'map'//trim(postfix))
       call rms_out%writeFITS(trim(prefix)//'rms'//trim(postfix))

       if (self%output_n_maps > 1) call outmaps(2)%p%writeFITS(trim(prefix)//'res'//trim(postfix))
       if (self%output_n_maps > 2) call outmaps(3)%p%writeFITS(trim(prefix)//'ncorr'//trim(postfix))
       if (self%output_n_maps > 3) call outmaps(4)%p%writeFITS(trim(prefix)//'bpcorr'//trim(postfix))
       if (self%output_n_maps > 4) call outmaps(5)%p%writeFITS(trim(prefix)//'mono'//trim(postfix))
       if (self%output_n_maps > 5) call outmaps(6)%p%writeFITS(trim(prefix)//'orb'//trim(postfix))
       if (self%output_n_maps > 6) call outmaps(7)%p%writeFITS(trim(prefix)//'sl'//trim(postfix))

    end if

    if (self%first_call) then
       call mpi_reduce(ntot,    i, 1, MPI_INTEGER, MPI_SUM, &
            & self%numprocs/2, self%info%comm, ierr)
       ntot = i
       call mpi_reduce(naccept, i, 1, MPI_INTEGER, MPI_SUM, &
            & self%numprocs/2, self%info%comm, ierr)
       naccept = i
    end if
    call wall_time(t2); t_tot(10) = t_tot(10) + t2-t1

    call wall_time(t6)
    if (self%myid == self%numprocs/2) then
       write(*,*) '  Time dist sky   = ', t_tot(9)
       write(*,*) '  Time sl precomp = ', t_tot(13)
       write(*,*) '  Time decompress = ', t_tot(11)
       write(*,*) '  Time alloc      = ', t_tot(18)
       write(*,*) '  Time project    = ', t_tot(1)
       write(*,*) '  Time orbital    = ', t_tot(2)
       write(*,*) '  Time sl interp  = ', t_tot(12)
       write(*,*) '  Time ncorr      = ', t_tot(3)
       write(*,*) '  Time gain       = ', t_tot(4)
       write(*,*) '  Time absgain    = ', t_tot(14)
       write(*,*) '  Time sel data   = ', t_tot(15)
       write(*,*) '  Time clean      = ', t_tot(5)
       write(*,*) '  Time noise      = ', t_tot(6)
       write(*,*) '  Time samp abs   = ', t_tot(16)
       write(*,*) '  Time samp bp    = ', t_tot(17)
       write(*,*) '  Time chisq      = ', t_tot(7)
       write(*,*) '  Time bin        = ', t_tot(8)
       write(*,*) '  Time scanlist   = ', t_tot(20)
       write(*,*) '  Time final      = ', t_tot(10)
       if (self%first_call) then
          write(*,*) '  Time total      = ', t6-t5, &
               & ', accept rate = ', real(naccept,sp) / ntot
       else
          write(*,*) '  Time total      = ', t6-t5, sum(t_tot(1:18))
       end if
    end if

    !stop

    ! Clean up temporary arrays
    deallocate(A_abscal, b_abscal, chisq_S)
    if (allocated(A_map)) deallocate(A_map, b_map)
    if (sA_map%init)  call dealloc_shared_2d_dp(sA_map)
    if (sb_map%init)  call dealloc_shared_3d_dp(sb_map)
    if (sb_mono%init) call dealloc_shared_3d_dp(sb_mono)
    if (allocated(b_mono)) deallocate(b_mono)
    if (allocated(sys_mono)) deallocate(sys_mono)
    if (allocated(slist)) deallocate(slist)

    if (allocated(outmaps)) then
       do i = 1, nout
          call outmaps(i)%p%dealloc
       end do
       deallocate(outmaps)
    end if

    if (sprocmask%init)  call dealloc_shared_1d_int(sprocmask)
    if (sprocmask2%init) call dealloc_shared_1d_int(sprocmask2)
    do j = 1, ndelta
       do i = 0, self%ndet
          if (smap_sky(i,j)%init) call dealloc_shared_2d_sp(smap_sky(i,j))
       end do
    end do
    deallocate(smap_sky)

    if (correct_sl) then
       do i = 1, self%ndet
          call self%slconv(i)%p%dealloc()
       end do
    end if

    call int2string(iter, ctext)
    call update_status(status, "tod_end"//ctext)

    ! Parameter to check if this is first time routine has been 
    self%first_call = .false.

  end subroutine process_LFI_tod


  !**************************************************
  !             Sub-process routines
  !**************************************************
  subroutine decompress_pointing_and_flags(self, scan, det, pix, psi, flag)
    implicit none
    class(comm_LFI_tod),                intent(in)  :: self
    integer(i4b),                       intent(in)  :: scan, det
    integer(i4b),        dimension(:),  intent(out) :: pix, psi, flag

    integer(i4b) :: i, j
    character(len=6) :: stext, dtext

    call huffman_decode2(self%scans(scan)%hkey, self%scans(scan)%d(det)%pix,  pix)
    call huffman_decode2(self%scans(scan)%hkey, self%scans(scan)%d(det)%psi,  psi, imod=self%npsi-1)
    call huffman_decode2(self%scans(scan)%hkey, self%scans(scan)%d(det)%flag, flag)

!!$    do j = 2, self%scans(scan)%ntod
!!$       pix(j)  = pix(j-1)  + pix(j)
!!$       psi(j)  = psi(j-1)  + psi(j)
!!$       flag(j) = flag(j-1) + flag(j)
!!$    end do
!!$    psi = modulo(psi,4096)

!!$    call int2string(scan,stext)
!!$    call int2string(det,dtext)
!!$    open(58,file='psi'//stext//'_'//dtext//'.dat')
!!$    do j = 1, self%scans(scan)%ntod
!!$       if (pix(j) == 6285034) then
!!$          write(58,*) scan, psi(j), j
!!$       end if
!!$    end do
!!$    close(58)

  end subroutine decompress_pointing_and_flags

  ! Sky signal template
  subroutine project_sky(self, map, pix, psi, flag, pmask, scan_id, &
       & s_sky, tmask, s_bp)
    implicit none
    class(comm_LFI_tod),                    intent(in)  :: self
    integer(i4b),        dimension(0:),     intent(in)  :: pmask
    type(shared_2d_sp),  dimension(0:),     intent(in)  :: map
    integer(i4b),        dimension(:,:),    intent(in)  :: pix, psi
    integer(i4b),        dimension(:,:),    intent(in)  :: flag
    integer(i4b),                           intent(in)  :: scan_id
    real(sp),            dimension(:,:),    intent(out) :: s_sky, tmask
    real(sp),            dimension(:,:),    intent(out), optional :: s_bp

    integer(i4b) :: i, ierr,det
    real(sp)     :: s

    ! s = T + Q * cos(2 * psi) + U * sin(2 * psi)
    ! T - temperature; Q, U - Stoke's parameters
    do det = 1, self%ndet
       if (.not. self%scans(scan_id)%d(det)%accept) cycle
       do i = 1, self%scans(scan_id)%ntod
          s_sky(i,det) = map(det)%a(1,pix(i,det)+1) + &
                       & map(det)%a(2,pix(i,det)+1) * self%cos2psi(psi(i,det)) + &
                       & map(det)%a(3,pix(i,det)+1) * self%sin2psi(psi(i,det))
          tmask(i,det) = pmask(pix(i,det)) 
          if (iand(flag(i,det),6111248) .ne. 0) tmask(i,det) = 0.
       end do
    end do

    if (present(s_bp)) then
       do det = 1, self%ndet
          if (.not. self%scans(scan_id)%d(det)%accept) cycle
          do i = 1, self%scans(scan_id)%ntod
             s =    map(0)%a(1,pix(i,det)+1) + &
                  & map(0)%a(2,pix(i,det)+1) * self%cos2psi(psi(i,det)) + &
                  & map(0)%a(3,pix(i,det)+1) * self%sin2psi(psi(i,det))
             s_bp(i,det)  = s_sky(i,det) - s
          end do
       end do
    end if

  end subroutine project_sky


  ! Compute map with white noise assumption from correlated noise 
  ! corrected and calibrated data, d' = (d-n_corr-n_temp)/gain 
  subroutine compute_orbital_dipole(self, ind, pix, s_orb)
    implicit none
    class(comm_LFI_tod),                 intent(in)  :: self
    integer(i4b),                        intent(in)  :: ind !scan nr/index
    integer(i4b),        dimension(:,:), intent(in)  :: pix
    real(sp),            dimension(:,:), intent(out) :: s_orb
    real(dp)             :: x, T_0, q, pix_dir(3), b, b_dot
    real(dp), parameter  :: h = 6.62607015d-34   ! Planck's constant [Js]
    integer(i4b)         :: i,j

    !T_0 = T_CMB*k_b/h !T_0 = T_CMB frequency
    !x = freq * 1.d9 / (2.d0*T_0) !freq is the center bandpass frequancy of the detector
    !q = x * (exp(2.d0*x)+1) / (exp(2.d0*x)-1) !frequency dependency of the quadrupole
    !b = sqrt(sum(self%scans(ind)%v_sun**2))/c !beta for the given scan

    do i = 1,self%ndet
       if (.not. self%scans(ind)%d(i)%accept) cycle
       do j=1,self%scans(ind)%ntod !length of the tod
          b_dot = dot_product(self%scans(ind)%v_sun, self%pix2vec(:,pix(j,i)))/c
          s_orb(j,i) = T_CMB  * b_dot !only dipole, 1.d6 to make it uK, as [T_CMB] = K
          !s_orb(j,i) = T_CMB  * 1.d6 * b_dot !only dipole, 1.d6 to make it uK, as [T_CMB] = K
          !s_orb(j,i) = T_CMB * 1.d6 * (b_dot + q*b_dot**2) ! with quadrupole
          !s_orb(j,i) = T_CMB * 1.d6 * (b_dot + q*((b_dot**2) - (1.d0/3.d0)*(b**2))) ! net zero monopole
       end do
   end do

  end subroutine compute_orbital_dipole

  ! Compute correlated noise term, n_corr
  ! TODO: Add fluctuation if operation == sample
  subroutine sample_n_corr(self, handle, scan, mask, s_sub, n_corr)
    implicit none
    class(comm_LFI_tod),               intent(in)     :: self
    type(planck_rng),                  intent(inout)  :: handle
    integer(i4b),                      intent(in)     :: scan
    real(sp),          dimension(:,:), intent(in)     :: mask, s_sub
    real(sp),          dimension(:,:), intent(out)    :: n_corr
    integer(i4b) :: i, j, k, l, n, m, nomp, ntod, ndet, err, omp_get_max_threads, meanrange, start, last
    integer*8    :: plan_fwd, plan_back
    logical(lgt) :: recompute, use_binned_psd
    real(sp)     :: sigma_0, alpha, nu_knee,  samprate, gain, mean, noise, signal
    real(dp)     :: nu, power
    real(sp),     allocatable, dimension(:) :: dt
    complex(spc), allocatable, dimension(:) :: dv
    real(sp),     allocatable, dimension(:) :: d_prime, diff
    
    ntod = self%scans(scan)%ntod
    ndet = self%ndet
    nomp = omp_get_max_threads()
    
    use_binned_psd = .false. !.true.
    meanrange = 20
    
    n = ntod + 1

    call sfftw_init_threads(err)
    call sfftw_plan_with_nthreads(nomp)

    allocate(dt(2*ntod), dv(0:n-1))
    call sfftw_plan_dft_r2c_1d(plan_fwd,  2*ntod, dt, dv, fftw_estimate + fftw_unaligned)
    call sfftw_plan_dft_c2r_1d(plan_back, 2*ntod, dv, dt, fftw_estimate + fftw_unaligned)
    deallocate(dt, dv)
    !$OMP PARALLEL PRIVATE(i,l,dt,dv,nu,sigma_0,alpha,nu_knee,d_prime,diff,start,last)
    allocate(dt(2*ntod), dv(0:n-1))
    allocate(d_prime(ntod))
    allocate(diff(ntod+1))
    diff = 0.d0
    !$OMP DO SCHEDULE(guided)
    do i = 1, ndet
       if (.not. self%scans(scan)%d(i)%accept) cycle
       gain = self%scans(scan)%d(i)%gain  ! Gain in V / K
       d_prime(:) = self%scans(scan)%d(i)%tod(:) - S_sub(:,i) * gain
       
       
       ! if (i == 4 .and. scan == 1) then
       !    open(23, file="d_prime1.unf", form="unformatted")
       !    write(23) d_prime
       !    close(23)
       ! end if


       sigma_0 = self%scans(scan)%d(i)%sigma0
       do j = 1,ntod
          if (mask(j,i) == 0.) then
             recompute = .true.
             start = max(j - meanrange, 1)
             last = min(j + meanrange, ntod)
             if (j > 1) then
                if (sum(mask(start:last, i)) < 5) recompute = .false.
             end if 

             if (recompute) then
                m = 1
                start = max(j - meanrange, 1)
                last = min(j + meanrange, ntod)
                do while (sum(mask(start:last, i)) < 2) 
                   ! Widen the search for unmasked pixels
                   m = m * 2
                   start = max(j - meanrange * m, 1)
                   last = min(j + meanrange * m, ntod)
                   if (meanrange * m > ntod) then
                      write(*,*) "Entire scan masked (this should not happen), see sample_n_corr", ntod, i, j, m
                      start = 1
                      last = ntod
                      exit
                   end if
                end do
                mean = sum(d_prime(start:last) * mask(start:last, i)) / sum(mask(start:last, i))
             end if
          ! if (mask(j,i) == 0.) then
          !    recompute = .true.
          !    if (j > 1) then
          !       if (mask(j-1,i) == 0.) recompute = .false.
          !    end if

             if (abs(d_prime(j) - mean) > 0.d0 * sigma_0) then 
                d_prime(j) = mean
             end if
          end if
       end do
       
       ! if (i == 4 .and. scan == 1) then
       !    open(23, file="d_prime2.unf", form="unformatted")
       !    write(23) d_prime
       !    close(23)
       ! end if


       dt(1:ntod)           = d_prime(:)
       dt(2*ntod:ntod+1:-1) = dt(1:ntod)

       call sfftw_execute_dft_r2c(plan_fwd, dt, dv)
       samprate = self%samprate
       sigma_0  = self%scans(scan)%d(i)%sigma0
       alpha    = self%scans(scan)%d(i)%alpha
       nu_knee  = self%scans(scan)%d(i)%fknee
       noise = 2.0 * ntod * sigma_0 ** 2
       ! if ((scan == 1) .and. (i == 1)) then
       !    write(*,*) "sigma, alpha, nu_knee, ntod", sigma_0, alpha, nu_knee, ntod
       ! end if
       if (trim(self%operation) == "sample") then
          dv(0)    = dv(0) + sqrt(noise) * rand_gauss(handle)  ! is this correct?
       end if
       do l = 1, n-1                                                      
          nu = l*(samprate/2)/(n-1)
          if ((use_binned_psd) .and. (allocated(self%scans(scan)%d(i)%log_n_psd))) then
             power = splint(self%scans(scan)%d(i)%log_nu,self%scans(scan)%d(i)%log_n_psd,self%scans(scan)%d(i)%log_n_psd2,log(nu))
             signal = exp(power) - noise
             !write(*,*) signal, noise * (nu/(nu_knee))**(alpha), nu, noise
          else
             signal = noise * (nu/(nu_knee))**(alpha)
          end if
          
          if (trim(self%operation) == "sample") then
             ! dv(l) = (dv(l) + sigma_0 * (rand_gauss(handle)  &
             !      + sqrt((nu/(nu_knee))**(-alpha)) * rand_gauss(handle)))& 
             !      * 1.d0/(1.d0 + (nu/(nu_knee))**(-alpha)) 
             dv(l) = (dv(l) + sqrt(noise) * rand_gauss(handle)  &
                  +  noise * sqrt(1 / signal) * rand_gauss(handle))& 
                  * 1.d0/(1.d0 + noise / signal) 
          else
             !dv(l) = dv(l) * 1.d0/(1.d0 + (nu/(nu_knee))**(-alpha))
             dv(l) = dv(l) * 1.d0/(1.d0 + noise / signal)
          end if
       end do
       call sfftw_execute_dft_c2r(plan_back, dv, dt)
       dt          = dt / (2*ntod)
       n_corr(:,i) = dt(1:ntod) 
       
       ! if ((i == 1) .and. (scan == 1)) then
       !    open(65,file='ps_ncorr.dat')
       !    do j = i, ntod
       !       write(65, *) n_corr(j,i)
       !    end do
       !    close(65)
       ! end if
       ! if (allocated(self%scans(scan)%d(i)%log_n_psd)) stop

       ! if (i == 1 .and. scan == 1) then
       !    open(23, file="d_prime.unf", form="unformatted")
       !    write(23) d_prime
       !    close(23)
       ! end if


!!$       if (self%myid == 0 .and. i == 2 .and. scan == 2 .and. .false.) then
!!$          open(58,file='tod.dat')
!!$          do j = 1, ntod
!!$             write(58,*) j, d_prime(j), n_corr(j,i)
!!$          end do
!!$          close(58)
!!$       end if

    end do
    !$OMP END DO                                                          
    deallocate(dt, dv)
    deallocate(d_prime)
    deallocate(diff)
    !$OMP END PARALLEL

    call sfftw_destroy_plan(plan_fwd)                                           
    call sfftw_destroy_plan(plan_back)                                          
  
  end subroutine sample_n_corr

  ! Compute gain as g = (d-n_corr-n_temp)/(map + dipole_orb), where map contains an 
  ! estimate of the stationary sky
  subroutine sample_gain(self, handle, det, scan_id, n_corr, mask, s_ref)
    implicit none
    class(comm_LFI_tod),               intent(inout)  :: self
    type(planck_rng),                  intent(inout)  :: handle
    integer(i4b),                      intent(in)     :: det, scan_id
    real(sp),            dimension(:), intent(in)     :: n_corr, mask, s_ref
    real(dp),            allocatable,  dimension(:)   :: d_only_wn
    real(dp)                                          :: curr_gain, ata
    real(dp)                                          :: curr_sigma

    allocate(d_only_wn(size(s_ref)))

    d_only_wn     = self%scans(scan_id)%d(det)%tod - n_corr
    ata           = sum(mask*s_ref**2)
    curr_gain     = sum(mask * d_only_wn * s_ref) / ata            
    curr_sigma    = self%scans(scan_id)%d(det)%sigma0 / sqrt(ata)  
    if (trim(self%operation) == 'optimize') then
       self%scans(scan_id)%d(det)%gain       = curr_gain
       self%scans(scan_id)%d(det)%gain_sigma = curr_sigma
    else
       ! TODO: Add fluctuation
       self%scans(scan_id)%d(det)%gain       = curr_gain
       self%scans(scan_id)%d(det)%gain_sigma = curr_sigma
    end if

    deallocate(d_only_wn)

  end subroutine sample_gain


  ! Compute gain as g = (d-n_corr-n_temp)/(map + dipole_orb), where map contains an 
  ! estimate of the stationary sky
  subroutine sample_smooth_gain(self)
    implicit none
    class(comm_LFI_tod),               intent(inout)  :: self

    integer(i4b) :: i, j, k, ndet, nscan_tot, ierr, binsize, nbin, b1, b2, n
    real(dp)     :: g0
    real(dp), allocatable, dimension(:)     :: vals
    real(dp), allocatable, dimension(:,:,:) :: g
    
    ndet       = self%ndet
    nscan_tot  = self%nscan_tot
    binsize    = 100

    ! Collect all gain estimates on the root processor
    allocate(g(nscan_tot,ndet,2), vals(binsize))
    g = 0.d0
    do j = 1, ndet
       do i = 1, self%nscan
          k        = self%scanid(i)
          if (.not. self%scans(i)%d(j)%accept) cycle
          g(k,j,1) = self%scans(i)%d(j)%gain
          g(k,j,2) = self%scans(i)%d(j)%gain_sigma
       end do
    end do
    if (self%myid == 0) then
       call mpi_reduce(mpi_in_place, g, size(g), MPI_DOUBLE_PRECISION, MPI_SUM, &
            & 0, self%comm, ierr)
    else
       call mpi_reduce(g,            g, size(g), MPI_DOUBLE_PRECISION, MPI_SUM, &
            & 0, self%comm, ierr)
    end if


    ! Perform joint sampling/smoothing
    if (self%myid == 0) then
       nbin = nscan_tot/binsize+1
       do j = 1, ndet
          do i = 1, nbin
             b1 = (i-1)*binsize+1
             b2 = min(i*binsize,nscan_tot)
             if (count(g(b1:b2,j,1) > 0) <= 1) cycle
             
             !g0 = 0.d0
             n  = 0
             do k = b1, b2
                if (g(k,j,1) == 0) cycle
                !g0 = g0 + g(k,j,1)
                n  = n+1
                vals(n) = g(k,j,1)
             end do
             g(b1:b2,j,1) = median(vals(1:n))  !g0/n
          end do
       end do
    end if

    ! Distribute and update results
    call mpi_bcast(g, size(g),  MPI_DOUBLE_PRECISION, 0, self%comm, ierr)    
    do j = 1, ndet
       do i = 1, self%nscan
          k        = self%scanid(i)
          self%scans(i)%d(j)%gain = g(k,j,1)
       end do
    end do

    deallocate(g, vals)

  end subroutine sample_smooth_gain

  subroutine accumulate_absgain_from_orbital(self, scan, det, mask, s_sub, &
       & s_orb, n_corr, A_abs, b_abs)
    implicit none
    class(comm_LFI_tod),             intent(in)     :: self
    integer(i4b),                    intent(in)     :: scan, det
    real(sp),          dimension(:), intent(in)     :: mask, s_sub, s_orb
    real(sp),          dimension(:), intent(in)     :: n_corr
    real(dp),                        intent(inout)  :: A_abs, b_abs

    integer(i4b) :: i
    real(dp)     :: data          ! Cleaned data in units of K
    real(dp)     :: inv_sigmasq  ! Inverse variance in units of K**-2

    inv_sigmasq = (self%scans(scan)%d(det)%gain / &
         & self%scans(scan)%d(det)%sigma0)**2
    do i = 1, self%scans(scan)%ntod
       data = (self%scans(scan)%d(det)%tod(i)-n_corr(i))/ &
            & self%scans(scan)%d(det)%gain - s_sub(i) 
       A_abs = A_abs + S_orb(i) * inv_sigmasq * mask(i) * S_orb(i)
       b_abs = b_abs + S_orb(i) * inv_sigmasq * mask(i) * data
    end do

  end subroutine accumulate_absgain_from_orbital

  ! Sample absolute gain from orbital dipole alone 
  subroutine sample_absgain_from_orbital(self, A_abs, b_abs)
    implicit none
    class(comm_LFI_tod),               intent(inout)  :: self
    real(dp),            dimension(:), intent(in)     :: A_abs, b_abs

    integer(i4b) :: i, j, ierr
    real(dp), allocatable, dimension(:) :: A, b, dgain, sigma

    ! Collect contributions from all cores
    allocate(A(self%ndet), b(self%ndet), dgain(self%ndet), sigma(self%ndet))
    call mpi_reduce(A_abs, A, self%ndet, MPI_DOUBLE_PRECISION, MPI_SUM, 0,&
         & self%info%comm, ierr)
    call mpi_reduce(b_abs, b, self%ndet, MPI_DOUBLE_PRECISION, MPI_SUM, 0,&
         & self%info%comm, ierr)

    ! Compute gain update and distribute to all cores
    if (self%myid == 0) then
       sigma = 1.d0/sqrt(A)
       dgain = b/A
       if (.false.) then
          ! Add fluctuation term if requested
       end if
       do j = 1, self%ndet
          write(*,fmt='(a,i5,a,3f8.3)') 'Orb gain -- d = ', j, ', dgain = ', &
               & 100*(dgain(j)-1), 100*sigma(j), (dgain(j)-1)/sigma(j)
       end do
    end if
    call mpi_bcast(dgain, self%ndet,  MPI_DOUBLE_PRECISION, 0, &
         & self%info%comm, ierr)
    call mpi_bcast(sigma, self%ndet,  MPI_DOUBLE_PRECISION, 0, &
         & self%info%comm, ierr)

    do j = 1, self%ndet
       do i = 1, self%nscan
          if(isNaN(dgain(j))) then
            write(*,*) "sample absgain", dgain(j), self%scans(i)%d(j)%gain
            dgain(j) = 1.d0
          end if
          self%scans(i)%d(j)%gain = dgain(j) * self%scans(i)%d(j)%gain
       end do
    end do

    deallocate(A, b, dgain, sigma)

  end subroutine sample_absgain_from_orbital
  
  !construct a sidelobe template in the time domain
  subroutine construct_sl_template(self, slconv, scan_id, nside, pix, psi, s_sl, polangle)
    implicit none
    class(comm_LFI_tod),                 intent(in)    :: self
    class(comm_conviqt),                 intent(in)    :: slconv
    integer(i4b),                        intent(in)    :: scan_id, nside
    integer(i4b),        dimension(:),   intent(in)    :: pix, psi
    real(dp),                            intent(in)   :: polangle
    real(sp),            dimension(:),   intent(out)   :: s_sl
    
    integer(i4b) :: j
    real(dp)     :: psi_

    do j=1, size(pix)
       psi_    = self%psi(psi(j))-polangle 
       s_sl(j) = slconv%interp(pix(j), psi_) 
    end do

  end subroutine construct_sl_template

  !compute the cleaned TOD from the computed TOD components
  subroutine compute_cleaned_tod(self, ntod, scan_num, s_sub, &
       & n_corr, d_calib)
    implicit none
    class(comm_LFI_tod),               intent(in)    :: self
    integer(i4b),                      intent(in)    :: ntod, scan_num
    real(sp),          dimension(:,:), intent(in)    :: s_sub
    real(sp),          dimension(:,:), intent(in)    :: n_corr
    real(sp),          dimension(:,:), intent(out)   :: d_calib

    integer(i4b) :: i

    !cleaned calibrated data = (rawTOD - corrNoise)/gain - orbitalDipole - sideLobes
    do i=1, self%ndet
       if (.not. self%scans(scan_num)%d(i)%accept) cycle
      d_calib(:,i) = (self%scans(scan_num)%d(i)%tod - n_corr(:,i)) / &
           & self%scans(scan_num)%d(i)%gain - s_sub(:,i)
    end do
  end subroutine compute_cleaned_tod


  ! Compute chisquare
  subroutine compute_chisq(self, scan, det, mask, s_sky, s_spur, &
       & n_corr, s_prop)
    implicit none
    class(comm_LFI_tod),             intent(inout)  :: self
    integer(i4b),                    intent(in)     :: scan, det
    real(sp),          dimension(:), intent(in)     :: mask, s_sky, s_spur
    real(sp),          dimension(:), intent(in)     :: n_corr
    real(sp),          dimension(:), intent(in), optional :: s_prop

    real(dp)     :: chisq, chisq_prop, d0, g
    integer(i4b) :: i, n

    chisq       = 0.d0
    chisq_prop  = 0.d0
    n           = 0
    g           = self%scans(scan)%d(det)%gain 
    do i = 1, self%scans(scan)%ntod
       if (mask(i) < 0.5) cycle 
       n     = n+1
       d0    = self%scans(scan)%d(det)%tod(i) - &
            & (g * s_spur(i) + n_corr(i))
       chisq = chisq + (d0 - g * s_sky(i))**2 
       if (present(s_prop)) then
          chisq_prop = chisq_prop + (d0 - g * s_prop(i))**2 
       end if
    end do
    chisq      = chisq      / self%scans(scan)%d(det)%sigma0**2

    if (present(s_prop)) then
       chisq_prop = chisq_prop / self%scans(scan)%d(det)%sigma0**2
       self%scans(scan)%d(det)%chisq_masked = chisq
       self%scans(scan)%d(det)%chisq_prop   = chisq_prop
    else
       self%scans(scan)%d(det)%chisq        = (chisq - n) / sqrt(2.d0*n)
    end if
    ! write(*,*) "chi2 :  ", scan, det, self%scanid(scan), &
    !      & self%scans(scan)%d(det)%chisq, self%scans(scan)%d(det)%sigma0
    !if(self%scans(scan)%d(det)%chisq > 2000.d0 .or. isNaN(self%scans(scan)%d(det)%chisq)) then
      !write(*,*) "chisq", scan, det, sum(mask), sum(s_sky), sum(s_sl), sum(s_orb), sum(n_corr)
    !end if
    
  end subroutine compute_chisq
  
  subroutine linspace(from, to, array)  ! Hat tip: https://stackoverflow.com/a/57211848/5238625
    implicit none
    real(dp), intent(in) :: from, to
    real(dp), intent(out) :: array(:)
    real(dp) :: range
    integer :: n, i
    n = size(array)
    range = to - from

    if (n == 0) return

    if (n == 1) then
       array(1) = from
       return
    end if


    do i=1, n
       array(i) = from + range * (i - 1) / (n - 1)
    end do
  end subroutine linspace

  ! Sample noise psd
  ! TODO: Add fluctuation term if operation == sample
  subroutine sample_noise_psd(self, handle, scan, mask, s_tot, n_corr)
    implicit none
    class(comm_LFI_tod),             intent(inout)  :: self
    type(planck_rng),                intent(inout)  :: handle
    integer(i4b),                    intent(in)     :: scan
    real(sp),          dimension(:,:), intent(in)     :: mask, s_tot, n_corr
    
    integer*8    :: plan_fwd
    integer(i4b) :: i, j, n, n_bins, l, nomp, omp_get_max_threads, err, ntod 
    integer(i4b) :: ndet
    real(dp)     :: s, res, log_nu, samprate, gain, dlog_nu
    
    real(sp),     allocatable, dimension(:) :: dt
    complex(spc), allocatable, dimension(:) :: dv
    real(sp),     allocatable, dimension(:) :: d_prime, diff
    real(dp),     allocatable, dimension(:) :: log_nu_bin_edges, psd
    integer(i4b), allocatable, dimension(:) :: n_modes
    
    ntod = self%scans(scan)%ntod
    ndet = self%ndet
    nomp = omp_get_max_threads()
    

    ! compute sigma_0 the old way
    do i = 1, ndet
       if (.not. self%scans(scan)%d(i)%accept) cycle
    
       s = 0.d0
       n = 0

       do j = 1, self%scans(scan)%ntod-1
          if (any(mask(j:j+1,i) < 0.5)) cycle
          res = (self%scans(scan)%d(i)%tod(j) - &
               & (self%scans(scan)%d(i)%gain * s_tot(j,i) + &
               & n_corr(j,i)) - &
               & (self%scans(scan)%d(i)%tod(j+1) - &
               & (self%scans(scan)%d(i)%gain * s_tot(j+1,i) + &
               & n_corr(j+1,i))))/sqrt(2.)
          s = s + res**2
          n = n + 1
       end do
       ! if ((i == 1) .and. (scan == 1)) then
       !    write(*,*) "sigma0: ", sqrt(s/(n-1))
       ! end if
       self%scans(scan)%d(i)%sigma0 = sqrt(s/(n-1))
    end do
    
    n = ntod + 1
    n_bins = 20

    call sfftw_init_threads(err)
    call sfftw_plan_with_nthreads(nomp)

    allocate(dt(2*ntod), dv(0:n-1))
    call sfftw_plan_dft_r2c_1d(plan_fwd,  2*ntod, dt, dv, fftw_estimate + fftw_unaligned)
    deallocate(dt, dv)
    
    do i = 1, ndet
       if (.not. allocated(self%scans(scan)%d(i)%log_n_psd)) allocate(self%scans(scan)%d(i)%log_n_psd(n_bins))
       if (.not. allocated(self%scans(scan)%d(i)%log_nu)) allocate(self%scans(scan)%d(i)%log_nu(n_bins))
       if (.not. allocated(self%scans(scan)%d(i)%log_n_psd2)) allocate(self%scans(scan)%d(i)%log_n_psd2(n_bins))
    end do
    
    !$OMP PARALLEL PRIVATE(i,l,j,dt,dv,log_nu,d_prime,log_nu_bin_edges,n_modes,psd,gain,dlog_nu)
    allocate(dt(2*ntod), dv(0:n-1))
    allocate(d_prime(ntod))
    
    allocate(log_nu_bin_edges(n_bins + 1))
    allocate(n_modes(n_bins))
    allocate(psd(n_bins))
    !$OMP DO SCHEDULE(guided)
    do i = 1, ndet
       if (.not. self%scans(scan)%d(i)%accept) cycle
    
       gain = self%scans(scan)%d(i)%gain
       d_prime(:) = self%scans(scan)%d(i)%tod(:) - s_tot(:, i) * gain
       do j = 1, ntod
          if (mask(j,i) == 0.) then
             dt(j) = n_corr(j,i) + rand_gauss(handle) * self%scans(scan)%d(i)%sigma0
          else
             dt(j) = d_prime(j)
          end if
       end do
       !dt(1:ntod)           = d_prime(:)
       dt(2*ntod:ntod+1:-1) = dt(1:ntod)

       ! if ((i == 1) .and. (scan == 1)) then
       !    open(65,file='ps_dt.dat')
       !    do j = 1, ntod
       !       write(65, *) dt(j)
       !    end do
       !    close(65)
       ! end if
              
       n_modes(:) = 0
       psd(:) = 0.d0

       samprate = self%samprate
       call sfftw_execute_dft_r2c(plan_fwd, dt, dv)
       call linspace(log(1*(samprate/2)/(n-1)),log(samprate/2), log_nu_bin_edges)

       dlog_nu = log_nu_bin_edges(2) - log_nu_bin_edges(1)
       
       ! if ((i == 1) .and. (scan == 1)) open(65,file='ps.dat') 

       do l = 1, n-1                                                      
          log_nu = log(l*(samprate/2)/(n-1))
          j = ceiling((log_nu - log_nu_bin_edges(1) + 1d-10) / dlog_nu)
          n_modes(j) = n_modes(j) + 1
          psd(j) = psd(j) + abs(dv(l)) ** 2
          ! if ((i == 1) .and. (scan == 1)) write(65, *) abs(dv(l)) ** 2, log_nu
       end do
       ! if ((i == 1) .and. (scan == 1)) close(65)
       
       if (trim(self%operation) == "sample") then
          ! use abs to prevent rare cases of negative power spectra
          ! (should have been samples from inverse gamma distribution) 
          self%scans(scan)%d(i)%log_n_psd(:) =  log(psd(:) / n_modes(:)) &
               & * abs(1.d0 + sqrt(2.d0 / n_modes(:)) * rand_gauss(handle)) 
       else
          self%scans(scan)%d(i)%log_n_psd(:) = log(psd(:) / n_modes(:))
       end if
       self%scans(scan)%d(i)%log_nu(:) = log_nu_bin_edges(1:n_bins) + 0.5d0 * dlog_nu
       ! if ((i == 1) .and. (scan == 1)) then
       !    open(65,file='ps_binned.dat')
       !    do j = 1, n_bins
       !       write(65, *) self%scans(scan)%d(i)%log_n_psd(j), self%scans(scan)%d(i)%log_nu(j)
       !    end do
       !    close(65)
       ! end if
       ! self%scans(scan)%d(i)%sigma0 = sqrt(exp(self%scans(scan)%d(i)%log_n_psd(n_bins)))
       ! if ((i == 1) .and. (scan == 1)) then
       !    write(*,*) "sigma0: ", self%scans(scan)%d(i)%sigma0
       
       ! end if
       
       call spline(self%scans(scan)%d(i)%log_nu,&
            self%scans(scan)%d(i)%log_n_psd,&
            0.d0,0.d0,self%scans(scan)%d(i)%log_n_psd2)
       ! if ((i == 1) .and. (scan == 1)) then
       !    open(65,file='ps_tod.dat')
       !    do j = 1, ntod
       !       write(65, *) n_corr(j,i), self%scans(scan)%d(i)%tod(j), &
       !            & s_tot(j,i), mask(j,i)
       !    end do
       !    close(65)
       ! end if
       ! if ((i == 1) .and. (scan == 1)) then
       !    open(65,file='ps_params.dat')
       !    write(65, '(4(E15.6E3))') self%scans(scan)%d(i)%gain, self%scans(scan)%d(i)%alpha, &
       !            & self%scans(scan)%d(i)%sigma0, self%scans(scan)%d(i)%fknee
       !    close(65)
       ! end if
    end do
    !$OMP END DO
    deallocate(dt, dv)
    deallocate(d_prime, psd, n_modes)
    deallocate(log_nu_bin_edges)
    
    !$OMP END PARALLEL
    
    call sfftw_destroy_plan(plan_fwd)                                           
  end subroutine sample_noise_psd

  ! Compute map with white noise assumption from correlated noise 
  ! corrected and calibrated data, d' = (d-n_corr-n_temp)/gain 
  subroutine compute_binned_map(self, data, pix, psi, flag, A, b, scan, comp_S, b_mono)
    implicit none
    class(comm_LFI_tod),                      intent(in)    :: self
    integer(i4b),                             intent(in)    :: scan
    real(sp),            dimension(1:,1:,1:),    intent(in)    :: data
    integer(i4b),        dimension(1:,1:),       intent(in)    :: pix, psi, flag
    real(dp),            dimension(1:,1:),    intent(inout) :: A
    real(dp),            dimension(1:,1:,1:), intent(inout) :: b
    real(dp),            dimension(1:,1:,1:),    intent(inout), optional :: b_mono
    logical(lgt),                             intent(in)    :: comp_S

    integer(i4b) :: det, i, j, t, pix_, off, nout, psi_
    real(dp)     :: inv_sigmasq

    nout        = size(b,dim=1)

    do det = 1, self%ndet
       if (.not. self%scans(scan)%d(det)%accept) cycle
       off         = 6 + 4*(det-1)
       inv_sigmasq = (self%scans(scan)%d(det)%gain/self%scans(scan)%d(det)%sigma0)**2
       do t = 1, self%scans(scan)%ntod
          
          if (iand(flag(t,det),6111248) .ne. 0) cycle
          
          pix_    = self%pix2ind(pix(t,det))
          psi_    = psi(t,det)
          
          A(1,pix_) = A(1,pix_) + 1.d0                                  * inv_sigmasq
          A(2,pix_) = A(2,pix_) + self%cos2psi(psi_)                    * inv_sigmasq
          A(3,pix_) = A(3,pix_) + self%cos2psi(psi_)**2                 * inv_sigmasq
          A(4,pix_) = A(4,pix_) + self%sin2psi(psi_)                    * inv_sigmasq
          A(5,pix_) = A(5,pix_) + self%cos2psi(psi_)*self%sin2psi(psi_) * inv_sigmasq
          A(6,pix_) = A(6,pix_) + self%sin2psi(psi_)**2                 * inv_sigmasq
          
          do i = 1, nout
             b(i,1,pix_) = b(i,1,pix_) + data(i,t,det)                      * inv_sigmasq
             b(i,2,pix_) = b(i,2,pix_) + data(i,t,det) * self%cos2psi(psi_) * inv_sigmasq
             b(i,3,pix_) = b(i,3,pix_) + data(i,t,det) * self%sin2psi(psi_) * inv_sigmasq
          end do
          
          if (present(b_mono)) then
             b_mono(1,pix_,det) = b_mono(1,pix_,det) +                      inv_sigmasq
             b_mono(2,pix_,det) = b_mono(2,pix_,det) + self%cos2psi(psi_) * inv_sigmasq
             b_mono(3,pix_,det) = b_mono(3,pix_,det) + self%sin2psi(psi_) * inv_sigmasq
          end if
          
          if (comp_S .and. det < self%ndet) then
             A(off+1,pix_) = A(off+1,pix_) + 1.d0               * inv_sigmasq 
             A(off+2,pix_) = A(off+2,pix_) + self%cos2psi(psi_) * inv_sigmasq
             A(off+3,pix_) = A(off+3,pix_) + self%sin2psi(psi_) * inv_sigmasq
             A(off+4,pix_) = A(off+4,pix_) + 1.d0               * inv_sigmasq
             do i = 1, nout
                b(i,det+3,pix_) = b(i,det+3,pix_) + data(i,t,det) * inv_sigmasq 
             end do
          end if
          
       end do
    end do

  end subroutine compute_binned_map


  subroutine finalize_binned_map(self, handle, sA_map, sb_map, outmaps, rms, chisq_S, Sfile, mask, sb_mono, sys_mono, condmap)
    implicit none
    class(comm_LFI_tod),                  intent(in)    :: self
    type(planck_rng),                     intent(inout) :: handle
    type(shared_2d_dp), intent(inout) :: sA_map
    type(shared_3d_dp), intent(inout) :: sb_map
    class(map_ptr),  dimension(1:),       intent(inout) :: outmaps
    class(comm_map),                      intent(inout) :: rms
    real(dp),        dimension(1:,1:),    intent(out),   optional :: chisq_S
    character(len=*),                     intent(in),    optional :: Sfile
    integer(i4b),    dimension(0:),       intent(in),    optional :: mask
    type(shared_3d_dp), intent(inout), optional :: sb_mono
    real(dp),        dimension(1:,1:,0:), intent(out),   optional :: sys_mono
    class(comm_map),                      intent(inout), optional :: condmap

    integer(i4b) :: i, j, k, l, nmaps, np, ierr, ndet, ncol, n_A, off
    integer(i4b) :: det, nout, np0, comm, myid, nprocs
    real(dp), allocatable, dimension(:,:)   :: A_inv
    real(dp), allocatable, dimension(:,:,:) :: b_tot
    real(dp), allocatable, dimension(:)     :: W, eta
    real(dp), allocatable, dimension(:,:)   :: A_tot
    class(comm_mapinfo), pointer :: info
    class(comm_map), pointer :: smap

    myid  = self%myid
    nprocs= self%numprocs
    comm  = self%comm
    np0   = self%info%np
    nout  = size(sb_map%a,dim=1)
    nmaps = self%info%nmaps
    ndet  = self%ndet
    if (present(chisq_S)) then
       ncol  = nmaps+ndet-1
       n_A   = nmaps*(nmaps+1)/2 + 4*(ndet-1)
    else
       ncol  = nmaps
       n_A   = nmaps*(nmaps+1)/2
    end if

    ! Collect contributions from all nodes
    call update_status(status, "tod_final1")
    call mpi_win_fence(0, sA_map%win, ierr)
    if (sA_map%myid_shared == 0) then
       call mpi_allreduce(MPI_IN_PLACE, sA_map%a, size(sA_map%a), &
            & MPI_DOUBLE_PRECISION, MPI_SUM, sA_map%comm_inter, ierr)
    end if
    call mpi_win_fence(0, sA_map%win, ierr)
    call mpi_win_fence(0, sb_map%win, ierr)
    if (sb_map%myid_shared == 0) then
       call mpi_allreduce(MPI_IN_PLACE, sb_map%a, size(sb_map%a), &
            & MPI_DOUBLE_PRECISION, MPI_SUM, sb_map%comm_inter, ierr)
    end if
    call mpi_win_fence(0, sb_map%win, ierr)
    if (present(sb_mono)) then
       call mpi_win_fence(0, sb_mono%win, ierr)
       if (sb_mono%myid_shared == 0) then
          call mpi_allreduce(MPI_IN_PLACE, sb_mono%a, size(sb_mono%a), &
               & MPI_DOUBLE_PRECISION, MPI_SUM, sb_mono%comm_inter, ierr)
       end if
       call mpi_win_fence(0, sb_mono%win, ierr)
    end if

!!$    if (self%myid == 0) then
!!$       do i = 1, size(sA_map%a,2)
!!$          if (any(sA_map%a(:,i) /= 0.d0)) then
!!$             write(*,*) 'pix = ', i-1
!!$             write(*,*) 'A   = ', sA_map%a(:,i)
!!$             write(*,*) 'b   = ', sb_map%a(:,:,i)
!!$          end if
!!$       end do
!!$    end if
!!$    call mpi_finalize(i)
!!$    stop

    allocate(A_tot(n_A,0:np0-1), b_tot(nout,ncol,0:np0-1), W(ncol), eta(nmaps))
    A_tot = sA_map%a(:,self%info%pix+1)
    b_tot = sb_map%a(:,:,self%info%pix+1)
    if (present(sb_mono)) then
       do j = 1, ndet
          sys_mono(:,nmaps+j,:) = sb_mono%a(:,self%info%pix+1,j)
       end do
    end if
    call update_status(status, "tod_final2")


    ! Solve for local map and rms
    if (present(Sfile)) then
       info => comm_mapinfo(self%comm, self%info%nside, 0, ndet-1, .false.)
       smap => comm_map(info)
    end if
    allocate(A_inv(ncol,ncol))
    !if (present(chisq_S)) smap%map = 0.d0
    if (present(chisq_S)) chisq_S = 0.d0
    do i = 0, np0-1
       if (all(b_tot(1,:,i) == 0.d0)) cycle

!!$       if (self%info%pix(i) == 100) then
!!$          write(*,*) i, self%info%pix(i)
!!$          write(*,*) 'A', A_tot(:,i)
!!$          write(*,*) 'a', b_tot(:,:,i)
!!$       end if

       A_inv      = 0.d0
       A_inv(1,1) = A_tot(1,i)
       A_inv(2,1) = A_tot(2,i)
       A_inv(1,2) = A_inv(2,1)
       A_inv(2,2) = A_tot(3,i)
       A_inv(3,1) = A_tot(4,i)
       A_inv(1,3) = A_inv(3,1)
       A_inv(3,2) = A_tot(5,i)
       A_inv(2,3) = A_inv(3,2)
       A_inv(3,3) = A_tot(6,i)
       if (present(chisq_S)) then
          do det = 1, ndet-1
             off           = 6 + 4*(det-1)
             A_inv(1,    3+det) = A_tot(off+1,i)
             A_inv(3+det,1    ) = A_inv(1,3+det)
             A_inv(2,    3+det) = A_tot(off+2,i)
             A_inv(3+det,2    ) = A_inv(2,3+det)
             A_inv(3,    3+det) = A_tot(off+3,i)
             A_inv(3+det,3    ) = A_inv(3,3+det)
             A_inv(3+det,3+det) = A_tot(off+4,i)
          end do
       end if

       if (present(condmap)) then
          call get_eigenvalues(A_inv, W)
          condmap%map(i,1) = log10(max(abs(maxval(W)/minval(W)),1.d0))
       end if
       
       call invert_singular_matrix(A_inv, 1d-12)
       do k = 1, nout
          b_tot(k,1:ncol,i) = matmul(A_inv,b_tot(k,1:ncol,i))
       end do
!!$       if (self%info%pix(i) == 100) then
!!$          write(*,*) 'b', b_tot(:,:,i)
!!$       end if 

       if (present(sb_mono)) sys_mono(1:nmaps,1:nmaps,i) = A_inv(1:nmaps,1:nmaps)
       if (present(Sfile)) then
          do j = 1, ndet-1
             smap%map(i,j) = b_tot(1,nmaps+j,i) / sqrt(A_inv(nmaps+j,nmaps+j))
          end do
       end if
       if (present(chisq_S)) then
          if (mask(self%info%pix(i+1)) == 0) cycle
          do j = 1, ndet-1
             if (A_inv(nmaps+j,nmaps+j) == 0.d0) cycle
             chisq_S(j,1) = chisq_S(j,1) + b_tot(1,nmaps+j,i)**2 / A_inv(nmaps+j,nmaps+j)
             chisq_S(j,2) = chisq_S(j,2) + b_tot(2,nmaps+j,i)**2 / A_inv(nmaps+j,nmaps+j)
          end do
       else
          do j = 1, nmaps
             rms%map(i,j) = sqrt(A_inv(j,j))  * 1.d6 ! uK
             do k = 1, nout
                outmaps(k)%p%map(i,j) = b_tot(k,j,i) * 1.d6 ! uK
             end do
             if (trim(self%operation) == 'sample') then
                ! Add random fluctuation
                call compute_hermitian_root(A_inv, 0.5d0)
                do l = 1, nmaps
                   eta(l) = rand_gauss(handle)
                end do
                outmaps(k)%p%map(i,:) = outmaps(k)%p%map(i,:) + matmul(A_inv,eta)
             end if
          end do
       end if
    end do

    if (present(chisq_S)) then
       if (myid == 0) then
          call mpi_reduce(mpi_in_place, chisq_S, size(chisq_S), &
               & MPI_DOUBLE_PRECISION, MPI_SUM, 0, comm, ierr)
       else
          call mpi_reduce(chisq_S,      chisq_S, size(chisq_S), &
               & MPI_DOUBLE_PRECISION, MPI_SUM, 0, comm, ierr)
       end if

       if (present(Sfile)) call smap%writeFITS(trim(Sfile))
    end if

    if (present(Sfile)) call smap%dealloc

    deallocate(A_inv,A_tot,b_tot, W, eta)

  end subroutine finalize_binned_map




!!$  subroutine sample_bp2(self, delta, map_sky, handle, chisq_S)
!!$    implicit none
!!$    class(comm_LFI_tod),               intent(inout)  :: self
!!$    real(dp), dimension(1:,1:),        intent(inout)  :: delta
!!$    real(dp), dimension(0:,1:,0:,1:),  intent(inout)  :: map_sky
!!$    type(planck_rng),                  intent(inout)  :: handle
!!$    real(dp), dimension(1:,1:),        intent(in)     :: chisq_S
!!$
!!$    integer(i4b) :: i, j, ierr
!!$    logical(lgt) :: accept
!!$    real(dp)     :: chisq_prop, chisq_curr, cp, cc, accept_rate
!!$
!!$    do j = 1, self%ndet
!!$       ! Summing chisq for current delta
!!$       chisq_curr = 0.d0
!!$       chisq_prop = 0.d0
!!$       do i = 1, self%nscan ! Sum chisq for all scans
!!$          if (.not. self%scans(i)%d(j)%accept) cycle
!!$          chisq_curr = chisq_curr + self%scans(i)%d(j)%chisq_masked 
!!$          chisq_prop = chisq_prop + self%scans(i)%d(j)%chisq_prop 
!!$       end do
!!$
!!$       call mpi_reduce(chisq_prop, cp, 1, MPI_DOUBLE_PRECISION, MPI_SUM, &
!!$            & 0, self%info%comm, ierr)
!!$       call mpi_reduce(chisq_curr, cc, 1, MPI_DOUBLE_PRECISION, MPI_SUM, &
!!$            & 0, self%info%comm, ierr)
!!$             
!!$       if (self%myid == 0) then
!!$          cp          = cp + chisq_S(j,2) 
!!$          cc          = cc + chisq_S(j,1)
!!$          accept_rate = exp(-0.5d0*(cp-cc))  
!!$          accept = (rand_uni(handle) < accept_rate)
!!$          write(*,*) 'S=',chisq_S(j,:)
!!$          write(*,fmt='(a,i3,a,f16.1,a,f10.1,a,f10.6)') "det = ", j, &
!!$               & ', c0 = ', cc, ', diff = ', cp-cc, ', delta = ', delta(j,1)
!!$       end if
!!$
!!$       ! Broadcast new saved data
!!$       call mpi_bcast(accept, 1,  MPI_LOGICAL, 0, self%info%comm, ierr)
!!$       if (accept) then
!!$          ! Set current to proposal
!!$          map_sky(:,:,j,1) = map_sky(:,:,j,2)
!!$          delta(j,1)       = delta(j,2)
!!$       end if
!!$    end do
!!$
!!$    ! Update mean
!!$    map_sky(:,:,0,:) = map_sky(:,:,1,:)
!!$    do i = 2, self%ndet
!!$       map_sky(:,:,0,:) = map_sky(:,:,0,:) + map_sky(:,:,i,:) 
!!$    end do
!!$    map_sky(:,:,0,:) = map_sky(:,:,0,:)/self%ndet
!!$    
!!$  end subroutine sample_bp2

  subroutine sample_bp(self, iter, delta, smap_sky, handle, chisq_S)
    implicit none
    class(comm_LFI_tod),                      intent(inout)  :: self
    integer(i4b),                             intent(in)     :: iter
    real(dp),            dimension(0:,1:,1:), intent(inout)  :: delta
    type(shared_2d_sp),  dimension(0:,1:),    intent(inout)  :: smap_sky
    type(planck_rng),                         intent(inout)  :: handle
    real(dp),            dimension(1:,1:),    intent(in)     :: chisq_S

    integer(i4b) :: i, j, ierr
    logical(lgt) :: accept
    real(dp)     :: chisq_prop, chisq_curr, cp, cc, accept_rate, diff

    if (self%myid == 0) then
       cp          = sum(chisq_S(:,2))
       cc          = sum(chisq_S(:,1))
       diff        = cp-cc
       accept_rate = exp(-0.5d0*diff)  
       if (trim(self%operation) == 'optimize') then
          accept = cp <= cc
       else
          accept = (rand_uni(handle) < accept_rate)
       end if
       if (accept) cc = cp
       if (.true. .or. mod(iter,2) == 0) then
          write(*,fmt='(a,f16.1,a,f10.1)') 'Rel bp c0 = ', cp, &
               & ', diff = ', diff
       else
          write(*,fmt='(a,f16.1,a,f10.1)') 'Abs bp c0 = ', cp, &
               & ', diff = ', diff
       end if
    end if

    ! Broadcast new saved data
    call mpi_bcast(accept, 1,  MPI_LOGICAL, 0, self%info%comm, ierr)
    if (accept) then
       ! Set current to proposal
       do i = 0, self%ndet
          if (self%myid_shared == 0) smap_sky(i,1)%a = smap_sky(i,2)%a
       end do
       delta(:,:,1) =  delta(:,:,2)
    end if
    
  end subroutine sample_bp

  function get_total_chisq(self, det)
    implicit none
    class(comm_LFI_tod), intent(in)  :: self
    integer(i4b),        intent(in)  :: det
    real(dp)                         :: get_total_chisq

    integer(i4b) :: i, ierr
    real(dp)     :: chisq, buffer

    chisq = 0.d0
    do i = 1, self%nscan ! Sum chisq for all scans
       if (.not. self%scans(i)%d(det)%accept) cycle
       chisq = chisq + self%scans(i)%d(det)%chisq 
    end do
    call mpi_reduce(chisq, buffer, 1, MPI_DOUBLE_PRECISION, MPI_SUM, &
         & 0, self%info%comm, ierr)

    get_total_chisq = buffer

  end function get_total_chisq

  subroutine output_scan_list(self, slist)
    implicit none
    class(comm_LFI_tod),                           intent(in)    :: self
    character(len=512), allocatable, dimension(:), intent(inout) :: slist

    integer(i4b)     :: i, j, mpistat(MPI_STATUS_SIZE), unit, ns, ierr
    character(len=4) :: pid

    if (self%myid == 0) then
       call int2string(self%myid, pid)
       unit = getlun()
       open(unit,file=trim(self%outdir)//'/filelist.txt', recl=512)
       write(unit,*) sum(self%nscanprproc)
       do i = 1, self%nscan
          if (trim(slist(i)) == '') cycle
          write(unit,*) trim(slist(i))
       end do
       deallocate(slist)
       do j = 1, self%numprocs-1
          ns = self%nscanprproc(j)
          allocate(slist(ns))
          call mpi_recv(slist, 512*ns, MPI_CHARACTER, j, 98, self%comm, mpistat, ierr)
          do i = 1, ns
             if (trim(slist(i)) == '') cycle
             write(unit,*) trim(slist(i))
          end do
          deallocate(slist)
       end do
       close(unit)
    else
       call mpi_send(slist, 512*self%nscan, MPI_CHARACTER, 0, 98, self%comm, ierr)
       deallocate(slist)
    end if
  end subroutine output_scan_list

  subroutine sample_mono(self, handle, sys_mono, res, rms, mask)
    implicit none
    class(comm_LFI_tod),                   intent(inout) :: self
    type(planck_rng),                      intent(inout) :: handle
    real(dp),         dimension(1:,1:,0:), intent(in)    :: sys_mono
    class(comm_map),                       intent(in)    :: res, rms, mask

    integer(i4b) :: i, j, k, nstep, nmaps, ndet, ierr
    real(dp)     :: t1, t2, s(3), b(3), sigma, chisq, chisq0, chisq_prop
    logical(lgt) :: accept
    real(dp), allocatable, dimension(:) :: mono0, mono_prop

    call wall_time(t1)

    nstep = 500
    sigma = 0.03d-6 ! RMS proposal in K
    nmaps = size(sys_mono, dim=1)
    ndet  = size(sys_mono, dim=2)-nmaps
    allocate(mono0(ndet), mono_prop(ndet))
 
    ! Initialize monopoles on existing values
    if (self%myid == 0) then
       do j = 1, ndet
          mono0(j) = self%mono(j)
       end do
    end if
    call mpi_bcast(mono0, ndet,  MPI_DOUBLE_PRECISION, 0, res%info%comm, ierr)

    ! Compute chisquare for old values; only include Q and U in evaluation; 
    ! add old correction to output map
    chisq = 0.d0
    do k = 0, res%info%np-1
       b = 0.d0
       do j = 1, ndet
          b = b + mono0(j) * sys_mono(:,nmaps+j,k)
       end do
       s = matmul(sys_mono(1:3,1:3,k),b) * 1.d6 ! uK
       if (mask%map(k,1) == 1.d0) then
          chisq = chisq + sum((res%map(k,2:3)-s(2:3))**2 / rms%map(k,2:3)**2)
       end if
    end do
    call mpi_reduce(chisq, chisq0, 1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, res%info%comm, ierr)

    do i = 1, nstep

       ! Propose new monopoles; force zero average
       if (res%info%myid == 0) then
          do j = 1, ndet
             mono_prop(j) = mono0(j) + sigma * rand_gauss(handle)
          end do
          mono_prop = mono_prop - mean(mono_prop)
       end if
       call mpi_bcast(mono_prop, ndet,  MPI_DOUBLE_PRECISION, 0, res%info%comm, ierr)

       ! Compute chisquare for new values; only include Q and U in evaluation
       chisq = 0.d0
       do k = 0, res%info%np-1
          b = 0.d0
          do j = 1, ndet
             b = b + mono_prop(j) * sys_mono(:,nmaps+j,k)
          end do
          s = matmul(sys_mono(1:3,1:3,k),b) * 1.d6 ! uK
          if (mask%map(k,1) == 1) then
             chisq = chisq + sum((res%map(k,2:3)-s(2:3))**2 / rms%map(k,2:3)**2)
          end if
       end do
       call mpi_reduce(chisq, chisq_prop, 1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, res%info%comm, ierr)

       ! Apply Metropolis rule or maximize
       if (res%info%myid == 0) then
          if (trim(self%operation) == 'optimize') then
             accept = chisq_prop <= chisq0
          else
             accept = (rand_uni(handle) < exp(-0.5d0 * (chisq_prop-chisq0)))
          end if
!!$          write(*,*) 'Mono chisq0 = ', chisq0, ', delta = ', chisq_prop-chisq0
!!$          write(*,*) 'm0 = ', real(mono0,sp)
!!$          write(*,*) 'm1 = ', real(mono_prop,sp)
       end if
       call mpi_bcast(accept, 1,  MPI_LOGICAL, 0, res%info%comm, ierr)

       if (accept) then
          mono0  = mono_prop
          chisq0 = chisq_prop
       end if

    end do

    ! Update parameters
    self%mono = mono0

    call wall_time(t2)
    if (res%info%myid == 0) then
       write(*,*) 'Time for monopole sampling = ', t2-t1
    end if

    deallocate(mono0, mono_prop)

  end subroutine sample_mono

  subroutine symmetrize_flags(self, flag)
    implicit none
    class(comm_LFI_tod),                      intent(inout) :: self
    integer(i4b),         dimension(1:,1:),   intent(inout) :: flag

    integer(i4b) :: i, det

    do det = 1, self%ndet
       do i = 1, size(flag,2)
          if (iand(flag(i,det),6111248) .ne. 0) then
             flag(i,self%partner(det)) = flag(i,det)
          end if
       end do
    end do

  end subroutine symmetrize_flags

  subroutine validate_psi(scan, psi)
    implicit none
    integer(i4b),                 intent(in)    :: scan
    integer(i4b), dimension(:,:), intent(inout) :: psi

    integer(i4b) :: i, j, ntod, diff0, diff
    logical(lgt) :: ok
    character(len=6) :: stext


    ntod = size(psi, dim=1)

!!$    diff0 = psi(1,1)-psi(1,2)
!!$    diff  = psi(1,3)-psi(1,4)
!!$    do i = 1, ntod
!!$       if (psi(i,1) == 0) psi(i,1) = modulo(psi(i,2) + diff0,4096) 
!!$       if (psi(i,2) == 0) psi(i,2) = modulo(psi(i,1) - diff0,4096)
!!$       if (psi(i,3) == 0) psi(i,3) = modulo(psi(i,4) + diff, 4096) 
!!$       if (psi(i,4) == 0) psi(i,4) = modulo(psi(i,3) - diff, 4096) 
!!$    end do
!!$
!!$    return

    diff0 = smallest_angle(psi(1,1), psi(1,2))
    do i = 2, ntod
       diff = smallest_angle(psi(i,1), psi(i,2))
       ok = abs(diff-diff0) < 50 
       if (.not. ok) then
          write(*,*) 'Potential psi problem in scan = ', scan, ', det = 1 or 2', diff0, diff, i
          call int2string(scan, stext)
          open(58,file='error12_'//stext//'.txt')
          do j = 1, ntod
             diff = smallest_angle(psi(j,1), psi(j,2))
             write(58,*) j, psi(j,1), psi(j,2), diff
          end do
          close(58)
          exit
       end if
    end do

    diff0 = smallest_angle(psi(1,3), psi(1,4))
    do i = 2, ntod
       diff = smallest_angle(psi(i,3), psi(i,4))
       ok = abs(diff-diff0) < 10 
       if (.not. ok) then
          write(*,*) 'Potential psi problem in scan = ', scan, ', det = 3 or 4', diff0, diff, i
          call int2string(scan, stext)
          open(58,file='error34_'//stext//'.txt')
          do j = 1, ntod
             diff = smallest_angle(psi(j,3), psi(j,4))
             write(58,*) j, psi(j,3), psi(j,4), diff
          end do
          close(58)

          exit
       end if
    end do

  end subroutine validate_psi

  function smallest_angle(x, y)
    integer(i4b), intent(in) :: x, y
    integer(i4b)             :: smallest_angle

    integer(i4b) :: a, b

    a = modulo(x-y, 4096)
    b = modulo(y-x, 4096)
    if (a < b) then
       smallest_angle = -a
    else
       smallest_angle =  b
    end if

  end function smallest_angle

end module comm_tod_LFI_mod
